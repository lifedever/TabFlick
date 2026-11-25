import Foundation

/// 从 GitHub 取发布信息：先走 REST API，不行（限流、超时）再走 github.com 网页侧的公开地址。
///
/// `api.github.com` 不登录时每个出口 IP 每小时只给 60 次，走代理时一个节点是很多人共用的，
/// 额度可能常年是用完的：2026-11-25 实测出口 216.234.140.91 `x-ratelimit-remaining: 0`，
/// 「检查更新」报「GitHub 返回 403」。网页侧（`/releases/latest` 的跳转、`releases.atom`）不算这个额度。
/// 都是公开地址的普通请求，不带 token、不改 User-Agent。
enum GitHubReleases {

    static let repo = "lifedever/TabFlick"

    enum OfferResult {
        case success(UpdateOffer?)
        case failure(String)
    }

    // MARK: - 检查更新

    static func fetchOffer(current: String, arch: String) async -> OfferResult {
        let api = await offerFromAPI(current: current, arch: arch)
        guard case .failure(let reason) = api else { return api }
        log("⬆️ API 取不到（\(reason)），改走网页")
        return await offerFromWeb(current: current, arch: arch)
    }

    private static func offerFromAPI(current: String, arch: String) async -> OfferResult {
        // 取列表不取 /releases/latest：落下好几版时，更新窗口要把这几版的说明都列出来
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 仓库还没公开 / 改名时是 404，不当错误
            if code == 404 { return .success(nil) }
            guard code == 200 else {
                return .failure(L10n.t("GitHub 返回 \(code)", "GitHub returned \(code)"))
            }
            guard let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure(L10n.t("无法解析发布信息", "Could not parse the release info"))
            }
            return .success(UpdateFeed.offer(from: releases, current: current, arch: arch))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func offerFromWeb(current: String, arch: String) async -> OfferResult {
        async let latest = latestTag()
        async let notes = atomNotes(timeout: 15)
        let tag: String
        switch await latest {
        case .success(let value): tag = value
        case .failure(let failure): return .failure(failure.message)
        }
        // 说明取不到也照样提示更新，更新窗口里写「更新说明取不到」
        return .success(UpdateFeed.offer(latestTag: tag, notes: await notes ?? [],
                                         current: current, arch: arch, repo: repo))
    }

    /// `/releases/latest` 跳到 `/releases/tag/v0.27.4`（不含草稿、预发布）。用 HEAD，只要跳转后的地址、不读页面。
    private static func latestTag() async -> Result<String, Failure> {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { return .failure(Failure(L10n.t("GitHub 返回 \(code)", "GitHub returned \(code)"))) }
            guard let url = response.url, let tag = UpdateFeed.tag(fromReleaseURL: url) else {
                return .failure(Failure(L10n.t("无法解析发布信息", "Could not parse the release info")))
            }
            return .success(tag)
        } catch {
            return .failure(Failure(error.localizedDescription))
        }
    }

    private struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func atomNotes(timeout: TimeInterval) async -> [ReleaseNote]? {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases.atom")!)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UpdateFeed.atomNotes(from: data)
    }

    // MARK: - 某一版的说明

    /// 按 tag 精确取这一版的说明（用 /latest 会在「装的不是最新版」时张冠李戴）。
    /// API 不行就从 `releases.atom` 里找（只有最近 10 版，刚升上来的那版总在里面）。
    static func notes(version: String, timeout: TimeInterval) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/tags/v\(version)")!)
        request.timeoutInterval = timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let body = json["body"] as? String, !body.isEmpty {
            return body
        }
        let body = await atomNotes(timeout: timeout)?.first { $0.version == version }?.body
        return body?.isEmpty == false ? body : nil
    }
}
