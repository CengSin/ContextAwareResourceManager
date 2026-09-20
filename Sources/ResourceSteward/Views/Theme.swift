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

    static func resolvePath(path: String?, bundleID: String?) -> String? {
        if let path, !path.isEmpty {
            if path.hasSuffix(".app") && FileManager.default.fileExists(atPath: path) {
                return path
            }
            if let range = path.range(of: ".app") {
                let sub = String(path[..<range.upperBound])
                if FileManager.default.fileExists(atPath: sub) {
                    return sub
                }
            }
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        if let bundleID, !bundleID.isEmpty {
            let root = ProcessFamily.rootBundleID(from: bundleID) ?? bundleID
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: root) {
                return url.path
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return url.path
            }
        }
        return (path?.isEmpty == false) ? path : nil
    }

    static func cached(_ path: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[path]
    }

    /// Load off the main thread into `cached(_:)`. `icon(forFile:)` hits disk;
    /// doing it on MainActor stalls the menu. Completes with `Void` because
    /// `NSImage` is not Sendable and cannot be returned across isolation.
    static func load(path: String?, bundleID: String? = nil) async {
        guard let resolved = resolvePath(path: path, bundleID: bundleID), !resolved.isEmpty else {
            return
        }
        if cached(resolved) != nil { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if cached(resolved) != nil {
                    continuation.resume()
                    return
                }
                guard FileManager.default.fileExists(atPath: resolved)
                    || resolved.hasSuffix(".app")
                    || resolved.contains(".app/") else {
                    continuation.resume()
                    return
                }
                let icon = NSWorkspace.shared.icon(forFile: resolved)
                icon.size = NSSize(width: 64, height: 64)
                lock.lock()
                images[resolved] = icon
                lock.unlock()
                continuation.resume()
            }
        }
    }
}

struct AppIconView: View {
    let path: String?
    var bundleID: String? = nil
    var processName: String? = nil
    var size: CGFloat = 24
    @State private var image: NSImage?

    private var resolvedPath: String? {
        AppIconCache.resolvePath(path: path, bundleID: bundleID)
    }

    private var cacheKey: String {
        "\(path ?? "")|\(bundleID ?? "")"
    }

    var body: some View {
        Group {
            if let nsImage = image ?? resolvedPath.flatMap(AppIconCache.cached) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
        .task(id: cacheKey) {
            guard let resolved = resolvedPath, !resolved.isEmpty else {
                image = nil
                return
            }
            if let cached = AppIconCache.cached(resolved) {
                image = cached
                return
            }
            await AppIconCache.load(path: path, bundleID: bundleID)
            image = AppIconCache.cached(resolved)
        }
    }

    private var fallbackIcon: some View {
        let name = (processName ?? "").lowercased()
        let p = (path ?? "").lowercased()
        let isCLI = name.contains("zsh") || name.contains("bash") || name.contains("python")
            || name.contains("node") || name.contains("git") || name.contains("ruby")
            || name.contains("cargo") || name.contains("brew") || name.contains("fish")
            || name.contains("sh") || p.contains("/bin/") || p.contains("/usr/bin")
        let isSystem = name.hasSuffix("d") || p.contains("/system/") || p.contains("/usr/libexec/")
            || name.contains("launchd") || name.contains("windowserver") || name.contains("kernel")

        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.primary.opacity(0.06))

            Image(systemName: isCLI ? "terminal.fill" : (isSystem ? "gearshape.2.fill" : "app.fill"))
                .font(.system(size: size * 0.52))
                .foregroundStyle(.secondary)
        }
    }
}

