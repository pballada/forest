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

    static let added = Color(nsColor: CodeTheme.forest.addedText)
    static let removed = Color(nsColor: CodeTheme.forest.removedText)

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

/// Colours used by the diff renderer (AppKit), from the code theme chosen in Settings.
@MainActor
enum DiffPalette {
    /// Looked up once per draw pass rather than once per colour.
    static var theme = CodeTheme.current

    static var background: NSColor { theme.background }
    static var text: NSColor { theme.text }
    static var secondaryText: NSColor { theme.secondaryText }
    static var addedText: NSColor { theme.addedText }
    static var removedText: NSColor { theme.removedText }
    static var addedBackground: NSColor { theme.addedBackground }
    static var removedBackground: NSColor { theme.removedBackground }
    static var addedHighlight: NSColor { theme.addedHighlight }
    static var removedHighlight: NSColor { theme.removedHighlight }
    static var gutter: NSColor { theme.gutter }
    static var gutterText: NSColor { theme.gutterText }
    static var header: NSColor { theme.header }
    static var headerText: NSColor { theme.headerText }
    static var selection: NSColor { theme.selection }
    static var filler: NSColor { theme.filler }
    static var separator: NSColor { theme.separator }
    static var keyword: NSColor { theme.keyword }
    static var type: NSColor { theme.type }
    static var string: NSColor { theme.string }
    static var comment: NSColor { theme.comment }
    static var number: NSColor { theme.number }
    static var attribute: NSColor { theme.attribute }
    static var key: NSColor { theme.key }
}
