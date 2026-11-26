// 商店目录签名的小工具（build-index.py 调它，一般不直接跑）。Ed25519，CryptoKit。
// 私钥只走标准输入输出，不进命令行参数（ps 看得到参数）。
//
//   swift sign.swift keygen                      → 两行：私钥 base64、公钥 base64
//   swift sign.swift public                      ← 私钥 base64；→ 公钥 base64
//   swift sign.swift sign <文件>                  ← 私钥 base64；→ 签名 base64
//   swift sign.swift verify <文件> <签名文件> <公钥 base64>…   退出码 0 = 有一把公钥对得上

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKeyFromStdin() -> Curve25519.Signing.PrivateKey {
    let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("私钥读不出来")
    }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(privateKeyFromStdin().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2:
    let key = privateKeyFromStdin()
    guard let data = FileManager.default.contents(atPath: args[1]) else { fail("读不到 \(args[1])") }
    guard let signature = try? key.signature(for: data) else { fail("签名失败") }
    print(signature.base64EncodedString())
case "verify" where args.count >= 4:
    guard let data = FileManager.default.contents(atPath: args[1]),
          let text = FileManager.default.contents(atPath: args[2]).map({ String(decoding: $0, as: UTF8.self) }),
          let signature = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { exit(1) }
    let ok = args.dropFirst(3).contains { key in
        guard let raw = Data(base64Encoded: key), let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: data)
    }
    exit(ok ? 0 : 1)
default:
    fail("用法见文件头")
}
