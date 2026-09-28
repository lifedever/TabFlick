import Foundation

// 多 Profile 选连接的判定表。改 ProfilePicker 必跑：
//   cd helper && swiftc -parse-as-library Sources/tabflick/ProfilePicker.swift \
//     checks/profile-picker-check.swift -o /tmp/profilecheck && /tmp/profilecheck
@main
struct ProfilePickerCheck {
    static func main() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        func c(_ id: UUID, _ current: String?, _ all: [String] = [], _ focused: Date? = nil) -> ProfilePicker.Candidate {
            .init(id: id, currentTitle: current, allTitles: all + (current.map { [$0] } ?? []), focusedAt: focused)
        }
        typealias R = ProfilePicker.Reason
        let cases: [(String, [ProfilePicker.Candidate], String?, UUID?, UUID, R)] = [
            ("标题对上 B（焦点记录却是 A）", [c(a, "Gmail", [], t1), c(b, "GitHub", [], t0)], "GitHub", a, b, .title),
            ("标题带后缀也认", [c(a, "Gmail"), c(b, "YouTube")], "YouTube - 正在播放音频", nil, b, .title),
            ("前缀不能是半个词", [c(a, "Git"), c(b, "GitHub")], "GitHub", nil, b, .title),
            ("当前标签都没对上，看全部标签", [c(a, "Gmail", ["Docs"]), c(b, "Mail", ["Calendar"])], "Calendar", nil, b, .anyTitle),
            ("标题撞了，看焦点", [c(a, "新标签页", [], t0), c(b, "新标签页", [], t1)], "新标签页", a, b, .focus),
            ("拿不到窗口标题，看焦点", [c(a, "x", [], t1), c(b, "y", [], t0)], nil, b, a, .focus),
            ("没有焦点记录（老扩展），看最近推送", [c(a, "x"), c(b, "y")], "z", b, b, .lastPush),
            ("什么都没有，固定挑一个", [c(b, "x"), c(a, "y")], nil, nil, a, .fallback),
        ]
        var failures = 0
        for (name, candidates, title, last, wantID, wantReason) in cases {
            guard let got = ProfilePicker.pick(candidates, windowTitle: title, lastPush: last) else {
                failures += 1; print("✗ \(name)：返回 nil"); continue
            }
            if got.id != wantID || got.reason != wantReason {
                failures += 1
                print("✗ \(name)：期望 \(wantID == a ? "A" : "B")/\(wantReason.rawValue)，实际 \(got.id == a ? "A" : "B")/\(got.reason.rawValue)")
            }
        }
        print(failures == 0 ? "全部通过（\(cases.count) 组）" : "\(failures) 项失败")
        if failures > 0 { fatalError("ProfilePicker 校验未通过") }
    }
}
