import Foundation

public struct AutoReclaimNotice: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let throttleCount: Int
    public let quitCount: Int
    public let names: [String]

    public init(throttleCount: Int, quitCount: Int, names: [String], id: UUID = UUID()) {
        self.id = id
        self.throttleCount = throttleCount
        self.quitCount = quitCount
        self.names = names
    }

    public var title: String { ReclaimNoticeCopy.level1Title }
    public var body: String {
        ReclaimNoticeCopy.level1Body(throttleCount: throttleCount, quitCount: quitCount, names: names)
    }
}

public enum ReclaimNoticeCopy: Sendable {
    public static let level1Title = "资源管家已自动处理"

    public static func level1Body(throttleCount: Int, quitCount: Int, names: [String]) -> String {
        var parts: [String] = []
        if throttleCount > 0 { parts.append("降低 \(throttleCount) 个优先级") }
        if quitCount > 0 { parts.append("请求退出 \(quitCount) 个应用") }
        var text = parts.isEmpty
            ? "没有需要处理的应用。"
            : "已按当前负载" + parts.joined(separator: "，") + "。"
        let shown = names.prefix(4)
        if !shown.isEmpty {
            text += " " + shown.joined(separator: "、")
            if names.count > 4 { text += " 等" }
        }
        return text
    }
}
