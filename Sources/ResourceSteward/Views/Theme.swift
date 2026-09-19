import AppKit
import ResourceStewardCore
import SwiftUI

enum Theme {
    static let panelWidth: CGFloat = 420
    static let panelHeight: CGFloat = 620

    static func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return Color(red: 0.22, green: 0.78, blue: 0.42)
        case .warning: return Color(red: 0.98, green: 0.74, blue: 0.18)
        case .critical: return Color(red: 1.0, green: 0.33, blue: 0.27)
        }
    }

    static func scoreColor(_ score: Double) -> Color {
        if score < 30 { return .secondary }
        if score < 60 { return Color(red: 0.95, green: 0.72, blue: 0.16) }
        if score < 85 { return Color(red: 0.96, green: 0.52, blue: 0.18) }
        return Color(red: 0.95, green: 0.32, blue: 0.26)
    }

    static func usageColor(_ percent: Double) -> Color {
        if percent >= 85 { return pressureColor(.critical) }
        if percent >= 60 { return pressureColor(.warning) }
        return pressureColor(.normal)
    }

    static func actionColor(_ action: SuggestedAction) -> Color {
        switch action {
        case .none: return .secondary
        case .throttle: return Color(red: 0.35, green: 0.62, blue: 0.95)
        case .freeze: return Color(red: 0.96, green: 0.52, blue: 0.18)
        case .quit: return Color(red: 0.95, green: 0.32, blue: 0.26)
        }
    }
}

enum AppIconCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: NSImage] = [:]
    private static let queue = DispatchQueue(label: "cc.resourcesteward.icons", qos: .userInitiated)

    static func cached(_ path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    /// Load off the main thread. `icon(forFile:)` hits disk; doing it on MainActor
    /// (主线程，处理点击和滚动的那条线程) stalls the menu.
    static func load(_ path: String) async -> NSImage {
        if let cached = cached(path) { return cached }
        return await withCheckedContinuation { continuation in
            queue.async {
                if let cached = cached(path) {
                    continuation.resume(returning: cached)
                    return
                }
                let icon = NSWorkspace.shared.icon(forFile: path)
                icon.size = NSSize(width: 64, height: 64)
                lock.lock()
                images[path] = icon
                lock.unlock()
                continuation.resume(returning: icon)
            }
        }
    }
}

struct AppIconView: View {
    let path: String?
    var size: CGFloat = 22
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let nsImage = image ?? path.flatMap(AppIconCache.cached) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Image(systemName: "app.dashed")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: path) {
            guard let path, !path.isEmpty else {
                image = nil
                return
            }
            if image != nil || AppIconCache.cached(path) != nil { return }
            image = await AppIconCache.load(path)
        }
    }
}
