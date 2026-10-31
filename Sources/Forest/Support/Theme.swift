import AppKit
import ForestCore
import SwiftUI

enum Theme {
    /// Forest's signature green: the app accent, HEAD's lane, primary buttons.
    static let leaf = Color(nsColor: .forestLeaf)
    static let leafGradient = LinearGradient(colors: [Color(red: 0.30, green: 0.82, blue: 0.48), Color(red: 0.09, green: 0.62, blue: 0.43)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
    static let moss = Color(red: 0.55, green: 0.78, blue: 0.30)
    static let sky = Color(red: 0.24, green: 0.62, blue: 0.95)
    static let sun = Color(red: 0.98, green: 0.72, blue: 0.22)

    /// Lane colours for the commit graph, tuned to stay vivid on both light and dark backgrounds.
    /// Lane 0 (HEAD) is leaf green.
    static let lanes: [Color] = [
        Color(red: 0.13, green: 0.70, blue: 0.43),  // green
        Color(red: 0.24, green: 0.56, blue: 0.98),  // blue
        Color(red: 0.95, green: 0.36, blue: 0.56),  // pink
        Color(red: 0.98, green: 0.60, blue: 0.20),  // orange
        Color(red: 0.62, green: 0.42, blue: 0.96),  // violet
        Color(red: 0.13, green: 0.73, blue: 0.80),  // teal
        Color(red: 0.93, green: 0.76, blue: 0.18),  // yellow
        Color(red: 0.92, green: 0.30, blue: 0.27),  // red
        Color(red: 0.40, green: 0.48, blue: 0.95),  // indigo
        Color(red: 0.45, green: 0.80, blue: 0.70),  // mint
    ]

    static func lane(_ index: Int) -> Color { lanes[((index % lanes.count) + lanes.count) % lanes.count] }

    /// Claude's warm coral, used for everything agent-related.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let claudeGradient = LinearGradient(colors: [Color(red: 0.93, green: 0.56, blue: 0.40), Color(red: 0.80, green: 0.38, blue: 0.30)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let forestGradient = LinearGradient(colors: [Color(red: 0.16, green: 0.72, blue: 0.50), Color(red: 0.08, green: 0.45, blue: 0.52)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)

    static let added = Color(nsColor: DiffPalette.addedText)
    static let removed = Color(nsColor: DiffPalette.removedText)

    static func color(for status: ChangeStatus) -> Color {
        switch status {
        case .modified: .orange
        case .added, .untracked: added
        case .deleted: removed
        case .renamed, .copied: .blue
        case .typeChanged: .purple
        case .conflicted: .red
        }
    }

    static func avatarColor(for key: String) -> Color {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return lane(Int(hash % UInt64(lanes.count)))
    }

    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
}

enum Format {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static let absolute: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// Compact history-column date: time today, weekday this week, date otherwise.
    static func compact(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    static func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension NSColor {
    /// A colour that adapts to light and dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { [.darkAqua, .vibrantDark].contains($0) } == true ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let forestLeaf = NSColor.dynamic(light: NSColor(hex: 0x1E9E5E), dark: NSColor(hex: 0x3CCB7F))
}

/// Colours used by the diff renderer (AppKit), shared with SwiftUI through `Theme`.
enum DiffPalette {
    static let addedText = NSColor.dynamic(light: NSColor(hex: 0x1F9D55), dark: NSColor(hex: 0x4ADE80))
    static let removedText = NSColor.dynamic(light: NSColor(hex: 0xD93F3F), dark: NSColor(hex: 0xF87171))
    static let addedBackground = NSColor.dynamic(light: NSColor(hex: 0x2FBF71, alpha: 0.12), dark: NSColor(hex: 0x2FBF71, alpha: 0.15))
    static let removedBackground = NSColor.dynamic(light: NSColor(hex: 0xF05252, alpha: 0.10), dark: NSColor(hex: 0xF05252, alpha: 0.14))
    static let addedHighlight = NSColor.dynamic(light: NSColor(hex: 0x2FBF71, alpha: 0.34), dark: NSColor(hex: 0x2FBF71, alpha: 0.38))
    static let removedHighlight = NSColor.dynamic(light: NSColor(hex: 0xF05252, alpha: 0.28), dark: NSColor(hex: 0xF05252, alpha: 0.36))
    static let gutter = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.03))
    static let gutterText = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.32))
    static let header = NSColor.dynamic(light: NSColor(hex: 0x1E9E5E, alpha: 0.07), dark: NSColor(hex: 0x3CCB7F, alpha: 0.09))
    static let headerText = NSColor.dynamic(light: NSColor(hex: 0x17804B), dark: NSColor(hex: 0x6EE7A8))
    static let selection = NSColor.dynamic(light: NSColor(hex: 0x1E9E5E, alpha: 0.20), dark: NSColor(hex: 0x3CCB7F, alpha: 0.24))
    static let filler = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
    static let separator = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))

    static let keyword = NSColor.dynamic(light: NSColor(hex: 0xAD3DA4), dark: NSColor(hex: 0xFF7AB2))
    static let type = NSColor.dynamic(light: NSColor(hex: 0x157A62), dark: NSColor(hex: 0x6BDFB8))
    static let string = NSColor.dynamic(light: NSColor(hex: 0xC2410C), dark: NSColor(hex: 0xFF9F6E))
    static let comment = NSColor.dynamic(light: NSColor(hex: 0x6B7785), dark: NSColor(hex: 0x8A96A3))
    static let number = NSColor.dynamic(light: NSColor(hex: 0x2B50C8), dark: NSColor(hex: 0xD9C97C))
    static let attribute = NSColor.dynamic(light: NSColor(hex: 0x8A5A00), dark: NSColor(hex: 0xFDB863))
    static let key = NSColor.dynamic(light: NSColor(hex: 0x1D6FB8), dark: NSColor(hex: 0x7CC4FA))
}
