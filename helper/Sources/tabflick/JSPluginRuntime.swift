import Foundation
import JavaScriptCore

// JS 插件的运行时（2026-11-06）：每个插件一个 JSContext，跑在自己的串行队列上，用到时才建（不用不占内存）。
//
// 插件能用的只有 `tabflick` 这个对象上的几样（register / fetch / storage / settings / toast / copy / openURL / openSettings / locale）
// 加 console 和 setTimeout。界面上的副作用（toast、拷贝、打开网址）由外面注入（`Bridge`），这个文件只依赖
// Foundation 和 JavaScriptCore，校验程序能单独编它（checks/plugin-runtime-check.swift）。
//
// 联网只放行 manifest 里声明的主机（`PluginNetPolicy`），**重定向也要再过一遍**：URLSession 默认自动跟随
// 302，白名单里的主机跳到别的域名就绕过去了。
//
// 跑死循环靠 JSC 的执行时限掐断：`JSContextGroupSetExecutionTimeLimit` 是私有接口，dlsym 动态查
// （同 WindowShadow 的做法），查不到就不设 —— 只上官方插件，这是第二道防线。

final class JSPluginRuntime: NSObject, @unchecked Sendable {
    /// 外面注入的副作用，全部在主线程上调。
    struct Bridge {
        var toast: (_ text: String, _ detail: String?) -> Void = { _, _ in }
        var copy: (_ text: String) -> Void = { _ in }
        var openURL: (_ url: URL) -> Void = { _ in }
        /// 打开设置里这个插件的那一页（天气还没填 Key 时，列表里那一行回车去填）
        var openSettings: () -> Void = {}
    }

    let manifest: PluginManifest
    private let directory: URL
    private let storageFile: URL?
    private let bridge: Bridge
    private let language: String
    private let queue: DispatchQueue
    /// 只在 queue 上碰
    private var context: JSContext?
    private var handlers: JSValue?
    private var storage: [String: Any] = [:]
    private var loadFailed = false
    /// 闲置多久卸掉 context（省内存，用户 2026-11-06：尽量少占资源）。下次调用时重新加载，存储在文件里不丢。
    private let idleUnload: TimeInterval
    /// 正在进行的调用（等网络的 Promise 也算）：有的话不卸
    private var pending = 0
    private var lastUse = Date.distantPast
    private var idleCheckScheduled = false
    /// context 现在在不在（校验程序用）
    var isLoaded: Bool { queue.sync { context != nil } }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static let features = ["enter", "clock"]

    /// 一次同步执行最多跑多久（秒）。异步等网络不算在内。
    static let executionLimit: Double = 2
    /// 响应体上限，超过就当失败（行情接口几 KB，防插件拉大文件撑内存）。
    static let maxResponseBytes = 4 << 20
    /// storage 序列化后的上限。
    static let maxStorageBytes = 1 << 20

    init(manifest: PluginManifest, directory: URL, storageFile: URL?, language: String, bridge: Bridge,
         idleUnload: TimeInterval = 10 * 60) {
        self.idleUnload = idleUnload
        self.manifest = manifest
        self.directory = directory
        self.storageFile = storageFile
        self.language = language
        self.bridge = bridge
        queue = DispatchQueue(label: "TabFlick.plugin.\(manifest.id)", qos: .userInitiated)
        super.init()
    }

    // MARK: - 调插件

    /// 调插件注册的 `name` 函数，结果（同步值或 Promise 的结果）转成 Foundation 对象在主线程回调。
    /// 函数不存在、抛异常、Promise 被拒绝、超时被掐断，都回调 nil。一次调用只回调一次。
    func call(_ name: String, _ arguments: [Any] = [], completion: @escaping @Sendable (Any?) -> Void) {
        queue.async { [self] in
            var finished = false
            pending += 1
            lastUse = Date()
            func finish(_ value: Any?) {
                guard !finished else { return }
                finished = true
                pending -= 1
                lastUse = Date()
                scheduleIdleCheck()
                DispatchQueue.main.async { completion(value) }
            }
            guard let context = loadIfNeeded(), let handlers,
                  let function = handlers.objectForKeyedSubscript(name), !function.isUndefined,
                  function.isObject else { finish(nil); return }
            context.exception = nil
            let result = function.call(withArguments: arguments)
            if let error = context.exception {
                logError("\(name)() threw", error)
                context.exception = nil
                finish(nil)
                return
            }
            guard let result, Self.isThenable(result) else { finish(result?.toObject()); return }
            let resolved: @convention(block) (JSValue?) -> Void = { value in finish(value?.toObject()) }
            let rejected: @convention(block) (JSValue?) -> Void = { [self] error in
                logError("\(name)() rejected", error)
                finish(nil)
            }
            result.invokeMethod("then", withArguments: [JSValue(object: resolved, in: context) as Any,
                                                       JSValue(object: rejected, in: context) as Any])
        }
    }

    /// 闲置检查（在插件队列上）：没有进行中的调用、而且 `idleUnload` 没被调用过，就卸掉 context。
    private func scheduleIdleCheck() {
        guard !idleCheckScheduled, context != nil else { return }
        idleCheckScheduled = true
        queue.asyncAfter(deadline: .now() + idleUnload) { [weak self] in
            guard let self else { return }
            self.idleCheckScheduled = false
            guard self.context != nil else { return }
            if self.pending == 0, Date().timeIntervalSince(self.lastUse) >= self.idleUnload {
                self.context = nil
                self.handlers = nil
                log("🧩 [\(self.manifest.id)] unloaded after being idle")
            } else {
                self.scheduleIdleCheck()
            }
        }
    }

    private static func isThenable(_ value: JSValue) -> Bool {
        guard value.isObject, let then = value.objectForKeyedSubscript("then") else { return false }
        return !then.isUndefined && then.isObject
    }

    // MARK: - 加载

    /// 第一次用时建 context、装 API、跑入口脚本。失败过就不再试（等下次重启或重装）。
    private func loadIfNeeded() -> JSContext? {
        if let context { return context }
        guard !loadFailed else { return nil }
        let script = directory.appendingPathComponent(manifest.main)
        guard let source = try? String(contentsOf: script, encoding: .utf8),
              let context = JSContext() else {
            loadFailed = true
            log("🧩 [\(manifest.id)] can't read \(manifest.main)")
            return nil
        }
        context.name = "TabFlick plugin \(manifest.id)"
        context.exceptionHandler = { context, exception in context?.exception = exception }
        Self.applyExecutionLimit(context)
        storage = readStorage()
        installAPI(context)
        context.evaluateScript(source, withSourceURL: script)
        if let error = context.exception {
            logError("load", error)
            loadFailed = true
            return nil
        }
        guard handlers != nil else {
            log("🧩 [\(manifest.id)] loaded but never called tabflick.register")
            loadFailed = true
            return nil
        }
        self.context = context
        log("🧩 [\(manifest.id)] loaded v\(manifest.version)")
        return context
    }

    private func logError(_ what: String, _ error: JSValue?) {
        let message = error?.toString() ?? "?"
        let line = error?.objectForKeyedSubscript("line")?.toString() ?? "?"
        log("🧩 [\(manifest.id)] \(what): \(message) (line \(line))")
    }

    // MARK: - API

    private func installAPI(_ context: JSContext) {
        let api = JSValue(newObjectIn: context)!

        let register: @convention(block) (JSValue?) -> Void = { [weak self] value in
            guard let value, value.isObject else { return }
            self?.handlers = value
        }
        api.setObject(register, forKeyedSubscript: "register" as NSString)
        api.setObject(language, forKeyedSubscript: "locale" as NSString)
        // 这个版本的 TabFlick 认哪些后来加的能力，插件据此决定给不给（老版本没有这一项）：
        // enter = 行的动作能进下一层，clock = 行尾画走秒的钟
        api.setObject(Self.features, forKeyedSubscript: "features" as NSString)

        let fetch: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] address, options in
            self?.fetch(address, options)
        }
        api.setObject(fetch, forKeyedSubscript: "fetch" as NSString)

        let storageAPI = JSValue(newObjectIn: context)!
        let get: @convention(block) (String) -> Any? = { [weak self] key in self?.storage[key] }
        // 按 JSON.stringify 的规则存：函数、undefined 拒掉（toObject 会把函数转成空字典，照存就错了），
        // 嵌套的函数丢掉、Date 变字符串，和插件作者对 JSON 的预期一致
        let set: @convention(block) (String, JSValue?) -> Bool = { [weak self] key, value in
            guard let self, let value,
                  let json = JSContext.current()?.objectForKeyedSubscript("JSON")?
                      .invokeMethod("stringify", withArguments: [value]),
                  json.isString, let data = json.toString()?.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return false }
            return self.store(key, object)
        }
        let remove: @convention(block) (String) -> Void = { [weak self] key in _ = self?.store(key, nil) }
        storageAPI.setObject(get, forKeyedSubscript: "get" as NSString)
        storageAPI.setObject(set, forKeyedSubscript: "set" as NSString)
        storageAPI.setObject(remove, forKeyedSubscript: "remove" as NSString)
        api.setObject(storageAPI, forKeyedSubscript: "storage" as NSString)

        // 设置项（manifest 里声明的下拉框、要用户填的文字）：每次现读，设置页改了下一次调用就生效。
        // 文字没填是空串；没声明过的键是 undefined
        let settingsAPI = JSValue(newObjectIn: context)!
        let manifest = self.manifest
        let getSetting: @convention(block) (String) -> Any? = { key in
            if let choice = manifest.choices.first(where: { $0.key == key }) { return PluginSettingsStore.value(manifest.id, choice) }
            return manifest.inputs.first { $0.key == key }.map { PluginSettingsStore.text(manifest.id, $0) }
        }
        settingsAPI.setObject(getSetting, forKeyedSubscript: "get" as NSString)
        api.setObject(settingsAPI, forKeyedSubscript: "settings" as NSString)

        let bridge = self.bridge
        let toast: @convention(block) (String, JSValue?) -> Void = { text, detail in
            let detailText = (detail?.isString ?? false) ? detail?.toString() : nil
            DispatchQueue.main.async { bridge.toast(String(text.prefix(200)), detailText.map { String($0.prefix(400)) }) }
        }
        let copy: @convention(block) (String) -> Void = { text in
            DispatchQueue.main.async { bridge.copy(text) }
        }
        let openURL: @convention(block) (String) -> Bool = { address in
            // 打开网页是用户看得见的动作，不限主机；但只认 http(s)，不让插件拉起别的 App 或读本机文件
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
            DispatchQueue.main.async { bridge.openURL(url) }
            return true
        }
        api.setObject(toast, forKeyedSubscript: "toast" as NSString)
        api.setObject(copy, forKeyedSubscript: "copy" as NSString)
        api.setObject(openURL, forKeyedSubscript: "openURL" as NSString)
        let openSettings: @convention(block) () -> Void = { DispatchQueue.main.async { bridge.openSettings() } }
        api.setObject(openSettings, forKeyedSubscript: "openSettings" as NSString)
        context.setObject(api, forKeyedSubscript: "tabflick" as NSString)

        let id = manifest.id
        let console = JSValue(newObjectIn: context)!
        let printer: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            log("🧩 [\(id)] " + parts.joined(separator: " "))
        }
        console.setObject(printer, forKeyedSubscript: "log" as NSString)
        console.setObject(printer, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let setTimeout: @convention(block) (JSValue?, Double) -> Void = { [weak self] callback, milliseconds in
            guard let self, let callback, callback.isObject else { return }
            let delay = min(max(milliseconds, 0), 60_000) / 1000
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.context != nil else { return }
                callback.call(withArguments: [])
            }
        }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    }

    // MARK: - fetch

    /// `tabflick.fetch(url, {headers, encoding, method, body})` → Promise<{status, text}>。
    /// 只放行 manifest 里声明的主机；encoding 认 "gbk"（腾讯、新浪的行情是 GBK）。
    private func fetch(_ address: String, _ options: JSValue?) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        // 只传网址时 options 是 JS 的 undefined（不是 nil），在它上面读属性会抛 TypeError，整个 fetch 就失败了
        let options = (options?.isObject ?? false) ? options : nil
        let hosts = manifest.hosts
        let id = manifest.id
        return JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self else { return }
            guard let url = URL(string: address), PluginNetPolicy.allows(url, hosts: hosts) else {
                log("🧩 [\(id)] fetch blocked: \(address.prefix(120))")
                reject?.call(withArguments: ["blocked: not in manifest hosts"])
                return
            }
            var request = URLRequest(url: url)
            if let method = options?.objectForKeyedSubscript("method"), method.isString,
               let name = method.toString()?.uppercased(), ["GET", "POST"].contains(name) {
                request.httpMethod = name
            }
            if let body = options?.objectForKeyedSubscript("body"), body.isString {
                request.httpBody = body.toString()?.data(using: .utf8)
            }
            if let headers = options?.objectForKeyedSubscript("headers")?.toDictionary() {
                for case let (name as String, value as String) in headers
                where !["host", "cookie", "content-length"].contains(name.lowercased()) {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }
            let encoding = options?.objectForKeyedSubscript("encoding")?.toString()?.lowercased()
            let task = self.session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    if let error {
                        reject?.call(withArguments: [error.localizedDescription])
                        return
                    }
                    guard let data, data.count <= Self.maxResponseBytes else {
                        reject?.call(withArguments: ["response too large"])
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    resolve?.call(withArguments: [["status": status, "text": Self.decode(data, encoding: encoding)]])
                }
            }
            task.resume()
        }
    }

    static func decode(_ data: Data, encoding: String?) -> String {
        if let encoding, ["gbk", "gb2312", "gb18030"].contains(encoding) {
            let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if let text = String(data: data, encoding: gb) { return text }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - storage

    /// 存一个值（nil = 删）。只收 JSON 能表示的值，整份超过上限就不存。写盘在插件队列上，先写临时文件再换。
    private func store(_ key: String, _ value: Any?) -> Bool {
        var next = storage
        if let value, !(value is NSNull) {
            guard JSONSerialization.isValidJSONObject([value]) else { return false }
            next[key] = value
        } else {
            next[key] = nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: next, options: [.sortedKeys]),
              data.count <= Self.maxStorageBytes else {
            log("🧩 [\(manifest.id)] storage.set(\(key)) refused: too large or not JSON")
            return false
        }
        storage = next
        if let storageFile {
            try? FileManager.default.createDirectory(at: storageFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: storageFile, options: .atomic)
        }
        return true
    }

    private func readStorage() -> [String: Any] {
        guard let storageFile, let data = try? Data(contentsOf: storageFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    // MARK: - 执行时限

    private static let setExecutionTimeLimit: (@convention(c) (JSContextGroupRef, Double,
        (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, UnsafeMutableRawPointer?) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else {
            log("🧩 JSContextGroupSetExecutionTimeLimit not found, plugins run without a time limit")
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (JSContextGroupRef, Double,
            (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?, UnsafeMutableRawPointer?) -> Void).self)
    }()

    private static func applyExecutionLimit(_ context: JSContext) {
        guard let set = setExecutionTimeLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return }
        set(group, executionLimit, { _, _ in true }, nil)
    }
}

extension JSPluginRuntime: URLSessionTaskDelegate {
    /// 重定向也只能去白名单里的主机，否则白名单里的地址 302 一下就绕过去了。
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PluginNetPolicy.allows(url, hosts: manifest.hosts) else {
            log("🧩 [\(manifest.id)] redirect blocked: \(request.url?.host ?? "?")")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
