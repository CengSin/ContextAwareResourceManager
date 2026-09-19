import AppKit
import ResourceStewardCore
import SwiftUI

enum Theme {
    static let panelWidth: CGFloat = 430
    static let panelHeight: CGFloat = 630

    // MARK: - Radius
    static let cornerRadiusCard: CGFloat = 10
    static let cornerRadiusPill: CGFloat = 20
    static let cornerRadiusIcon: CGFloat = 6

    // MARK: - Semantic Colors
    static func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return Color(red: 0.20, green: 0.82, blue: 0.50) // Emerald Green
        case .warning: return Color(red: 0.98, green: 0.73, blue: 0.16) // Amber Gold
        case .critical: return Color(red: 0.98, green: 0.35, blue: 0.30) // Coral Red
        }
    }

    static func scoreColor(_ score: Double) -> Color {
        if score < 30 { return .secondary }
        if score < 60 { return Color(red: 0.96, green: 0.72, blue: 0.18) }
        if score < 85 { return Color(red: 0.98, green: 0.52, blue: 0.20) }
        return Color(red: 0.98, green: 0.35, blue: 0.30)
    }

    static func usageColor(_ percent: Double) -> Color {
        if percent >= 85 { return pressureColor(.critical) }
        if percent >= 60 { return pressureColor(.warning) }
        return pressureColor(.normal)
    }

    static func actionColor(_ action: SuggestedAction) -> Color {
        switch action {
        case .none: return .secondary
        case .throttle: return Color(red: 0.32, green: 0.62, blue: 0.98) // Electric Blue
        case .freeze: return Color(red: 0.98, green: 0.54, blue: 0.18) // Warm Amber
        case .quit: return Color(red: 0.98, green: 0.34, blue: 0.30) // Coral Rose
        }
    }

    static let favoriteColor = Color(red: 0.68, green: 0.46, blue: 0.96) // Soft Violet
    static let foregroundColor = Color(red: 0.22, green: 0.80, blue: 0.52) // Mint
}

// MARK: - Subtle Card Modifier
struct ModernCardModifier: ViewModifier {
    var isHovered: Bool = false
    var cornerRadius: CGFloat = Theme.cornerRadiusCard
    var padding: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.14 : 0.07),
                        lineWidth: 0.75
                    )
            )
    }
}

extension View {
    func modernCard(isHovered: Bool = false, cornerRadius: CGFloat = Theme.cornerRadiusCard, padding: CGFloat = 10) -> some View {
        self.modifier(ModernCardModifier(isHovered: isHovered, cornerRadius: cornerRadius, padding: padding))
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
    /// stalls the menu.
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
    var size: CGFloat = 24
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let nsImage = image ?? path.flatMap(AppIconCache.cached) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
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
