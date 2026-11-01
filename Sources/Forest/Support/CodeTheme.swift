import AppKit

/// A colour theme for code surfaces: the diff canvas, its header and cards.
/// Fixed themes use the published palettes of popular terminal and editor schemes; Forest follows the system appearance.
struct CodeTheme: Identifiable, Equatable {
    let id: String
    let name: String
    /// nil follows the system appearance.
    let isDark: Bool?
    let background: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let accent: NSColor
    let addedText: NSColor
    let removedText: NSColor
    let addedBackground: NSColor
    let removedBackground: NSColor
    let addedHighlight: NSColor
    let removedHighlight: NSColor
    let gutter: NSColor
    let gutterText: NSColor
    let header: NSColor
    let headerText: NSColor
    let selection: NSColor
    let filler: NSColor
    let separator: NSColor
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let attribute: NSColor
    let key: NSColor

    static func == (lhs: CodeTheme, rhs: CodeTheme) -> Bool { lhs.id == rhs.id }

    var appearance: NSAppearance? {
        isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
    }

    /// Builds a fixed theme from a scheme's base colours; tints are derived so every theme reads the same way.
    init(id: String, name: String, dark: Bool, background: UInt32, text: UInt32, comment: UInt32, accent: UInt32,
         added: UInt32, removed: UInt32, keyword: UInt32, type: UInt32, string: UInt32, number: UInt32,
         attribute: UInt32, key: UInt32) {
        let fg = NSColor(hex: text)
        self.id = id
        self.name = name
        isDark = dark
        self.background = NSColor(hex: background)
        self.text = fg
        secondaryText = NSColor(hex: comment)
        self.accent = NSColor(hex: accent)
        addedText = NSColor(hex: added)
        removedText = NSColor(hex: removed)
        addedBackground = NSColor(hex: added, alpha: dark ? 0.14 : 0.12)
        removedBackground = NSColor(hex: removed, alpha: dark ? 0.14 : 0.10)
        addedHighlight = NSColor(hex: added, alpha: dark ? 0.34 : 0.28)
        removedHighlight = NSColor(hex: removed, alpha: dark ? 0.34 : 0.24)
        gutter = fg.withAlphaComponent(0.035)
        gutterText = NSColor(hex: comment)
        header = NSColor(hex: accent, alpha: dark ? 0.12 : 0.08)
        headerText = NSColor(hex: accent)
        selection = NSColor(hex: accent, alpha: dark ? 0.26 : 0.20)
        filler = fg.withAlphaComponent(0.06)
        separator = fg.withAlphaComponent(0.10)
        self.keyword = NSColor(hex: keyword)
        self.type = NSColor(hex: type)
        self.string = NSColor(hex: string)
        self.comment = NSColor(hex: comment)
        self.number = NSColor(hex: number)
        self.attribute = NSColor(hex: attribute)
        self.key = NSColor(hex: key)
    }

    private init(forest: Void) {
        id = "forest"
        name = "Forest (matches system)"
        isDark = nil
        background = .textBackgroundColor
        text = .labelColor
        secondaryText = .secondaryLabelColor
        accent = .forestLeaf
        addedText = .dynamic(light: NSColor(hex: 0x1F9D55), dark: NSColor(hex: 0x4ADE80))
        removedText = .dynamic(light: NSColor(hex: 0xD93F3F), dark: NSColor(hex: 0xF87171))
        addedBackground = .dynamic(light: NSColor(hex: 0x2FBF71, alpha: 0.12), dark: NSColor(hex: 0x2FBF71, alpha: 0.15))
        removedBackground = .dynamic(light: NSColor(hex: 0xF05252, alpha: 0.10), dark: NSColor(hex: 0xF05252, alpha: 0.14))
        addedHighlight = .dynamic(light: NSColor(hex: 0x2FBF71, alpha: 0.34), dark: NSColor(hex: 0x2FBF71, alpha: 0.38))
        removedHighlight = .dynamic(light: NSColor(hex: 0xF05252, alpha: 0.28), dark: NSColor(hex: 0xF05252, alpha: 0.36))
        gutter = .dynamic(light: NSColor(white: 0, alpha: 0.025), dark: NSColor(white: 1, alpha: 0.03))
        gutterText = .dynamic(light: NSColor(white: 0, alpha: 0.32), dark: NSColor(white: 1, alpha: 0.32))
        header = .dynamic(light: NSColor(hex: 0x1E9E5E, alpha: 0.07), dark: NSColor(hex: 0x3CCB7F, alpha: 0.09))
        headerText = .dynamic(light: NSColor(hex: 0x17804B), dark: NSColor(hex: 0x6EE7A8))
        selection = .dynamic(light: NSColor(hex: 0x1E9E5E, alpha: 0.20), dark: NSColor(hex: 0x3CCB7F, alpha: 0.24))
        filler = .dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.05))
        separator = .dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08))
        keyword = .dynamic(light: NSColor(hex: 0xAD3DA4), dark: NSColor(hex: 0xFF7AB2))
        type = .dynamic(light: NSColor(hex: 0x157A62), dark: NSColor(hex: 0x6BDFB8))
        string = .dynamic(light: NSColor(hex: 0xC2410C), dark: NSColor(hex: 0xFF9F6E))
        comment = .dynamic(light: NSColor(hex: 0x6B7785), dark: NSColor(hex: 0x8A96A3))
        number = .dynamic(light: NSColor(hex: 0x2B50C8), dark: NSColor(hex: 0xD9C97C))
        attribute = .dynamic(light: NSColor(hex: 0x8A5A00), dark: NSColor(hex: 0xFDB863))
        key = .dynamic(light: NSColor(hex: 0x1D6FB8), dark: NSColor(hex: 0x7CC4FA))
    }

    static let forest = CodeTheme(forest: ())

    // Solarized as in iTerm2's built-in preset.
    static let solarizedDark = CodeTheme(id: "solarizedDark", name: "Solarized Dark", dark: true,
        background: 0x002B36, text: 0x839496, comment: 0x586E75, accent: 0x268BD2, added: 0x859900, removed: 0xDC322F,
        keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682, attribute: 0xCB4B16, key: 0x268BD2)
    static let solarizedLight = CodeTheme(id: "solarizedLight", name: "Solarized Light", dark: false,
        background: 0xFDF6E3, text: 0x657B83, comment: 0x93A1A1, accent: 0x268BD2, added: 0x859900, removed: 0xDC322F,
        keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682, attribute: 0xCB4B16, key: 0x268BD2)
    static let dracula = CodeTheme(id: "dracula", name: "Dracula", dark: true,
        background: 0x282A36, text: 0xF8F8F2, comment: 0x6272A4, accent: 0xBD93F9, added: 0x50FA7B, removed: 0xFF5555,
        keyword: 0xFF79C6, type: 0x8BE9FD, string: 0xF1FA8C, number: 0xBD93F9, attribute: 0x50FA7B, key: 0x8BE9FD)
    static let oneDark = CodeTheme(id: "oneDark", name: "One Dark", dark: true,
        background: 0x282C34, text: 0xABB2BF, comment: 0x5C6370, accent: 0x61AFEF, added: 0x98C379, removed: 0xE06C75,
        keyword: 0xC678DD, type: 0xE5C07B, string: 0x98C379, number: 0xD19A66, attribute: 0x56B6C2, key: 0xE06C75)
    static let monokai = CodeTheme(id: "monokai", name: "Monokai", dark: true,
        background: 0x272822, text: 0xF8F8F2, comment: 0x75715E, accent: 0x66D9EF, added: 0xA6E22E, removed: 0xF92672,
        keyword: 0xF92672, type: 0x66D9EF, string: 0xE6DB74, number: 0xAE81FF, attribute: 0xA6E22E, key: 0xFD971F)
    static let nord = CodeTheme(id: "nord", name: "Nord", dark: true,
        background: 0x2E3440, text: 0xD8DEE9, comment: 0x616E88, accent: 0x88C0D0, added: 0xA3BE8C, removed: 0xBF616A,
        keyword: 0x81A1C1, type: 0x8FBCBB, string: 0xA3BE8C, number: 0xB48EAD, attribute: 0xD08770, key: 0x88C0D0)
    static let gruvboxDark = CodeTheme(id: "gruvboxDark", name: "Gruvbox Dark", dark: true,
        background: 0x282828, text: 0xEBDBB2, comment: 0x928374, accent: 0x83A598, added: 0xB8BB26, removed: 0xFB4934,
        keyword: 0xFB4934, type: 0xFABD2F, string: 0xB8BB26, number: 0xD3869B, attribute: 0x8EC07C, key: 0x83A598)
    static let tokyoNight = CodeTheme(id: "tokyoNight", name: "Tokyo Night", dark: true,
        background: 0x1A1B26, text: 0xC0CAF5, comment: 0x565F89, accent: 0x7AA2F7, added: 0x9ECE6A, removed: 0xF7768E,
        keyword: 0xBB9AF7, type: 0x7DCFFF, string: 0x9ECE6A, number: 0xFF9E64, attribute: 0xE0AF68, key: 0x7AA2F7)
    static let catppuccinMocha = CodeTheme(id: "catppuccinMocha", name: "Catppuccin Mocha", dark: true,
        background: 0x1E1E2E, text: 0xCDD6F4, comment: 0x6C7086, accent: 0x89B4FA, added: 0xA6E3A1, removed: 0xF38BA8,
        keyword: 0xCBA6F7, type: 0xF9E2AF, string: 0xA6E3A1, number: 0xFAB387, attribute: 0x94E2D5, key: 0x89B4FA)
    static let githubDark = CodeTheme(id: "githubDark", name: "GitHub Dark", dark: true,
        background: 0x0D1117, text: 0xE6EDF3, comment: 0x8B949E, accent: 0x58A6FF, added: 0x3FB950, removed: 0xF85149,
        keyword: 0xFF7B72, type: 0xFFA657, string: 0xA5D6FF, number: 0x79C0FF, attribute: 0xD2A8FF, key: 0x79C0FF)
    static let githubLight = CodeTheme(id: "githubLight", name: "GitHub Light", dark: false,
        background: 0xFFFFFF, text: 0x1F2328, comment: 0x6E7781, accent: 0x0969DA, added: 0x1A7F37, removed: 0xCF222E,
        keyword: 0xCF222E, type: 0x953800, string: 0x0A3069, number: 0x0550AE, attribute: 0x8250DF, key: 0x0550AE)

    static let all: [CodeTheme] = [
        solarizedDark, solarizedLight, dracula, oneDark, monokai, nord, gruvboxDark, tokyoNight, catppuccinMocha,
        githubDark, githubLight, forest,
    ]
    static let defaultID = solarizedDark.id

    static func named(_ id: String) -> CodeTheme { all.first { $0.id == id } ?? solarizedDark }

    /// The theme chosen in Settings.
    static var current: CodeTheme { named(UserDefaults.standard.string(forKey: SettingsKey.codeTheme) ?? defaultID) }
}
