import AppKit
import ForestTerminal
import SwiftUI

/// Forest's theme: one palette for the whole window — sidebar, panels, diffs and the embedded terminal.
/// Fixed themes use the published palettes of popular terminal and editor schemes; "Automatic" pairs
/// Forest Day and Forest Night and follows the system appearance.
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

    // Interface surfaces, derived from the scheme so every theme reads the same way.
    /// Behind the sidebar and the inspector: a step away from the canvas.
    let sidebar: NSColor
    /// Raised things: cards, popovers, the tab bar.
    let elevated: NSColor
    /// Hairlines between regions.
    let border: NSColor
    let tertiaryText: NSColor
    let warning: NSColor
    let agent: NSColor

    /// Terminal colours, light and dark variants for Automatic.
    let terminalLight: TerminalPalette
    let terminalDark: TerminalPalette

    static func == (lhs: CodeTheme, rhs: CodeTheme) -> Bool { lhs.id == rhs.id }

    var appearance: NSAppearance? {
        isDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
    }

    var colorScheme: ColorScheme? { isDark.map { $0 ? .dark : .light } }

    struct TerminalPalette: Equatable {
        var background: UInt32
        var foreground: UInt32
        var cursor: UInt32
        var selection: UInt32
        /// ANSI 0–15.
        var ansi: [UInt32]
    }

    /// Builds a fixed theme from a scheme's base colours.
    init(id: String, name: String, dark: Bool, background: UInt32, text: UInt32, comment: UInt32, accent: UInt32,
         added: UInt32, removed: UInt32, keyword: UInt32, type: UInt32, string: UInt32, number: UInt32,
         attribute: UInt32, key: UInt32, warning: UInt32, agent: UInt32 = 0xD97757, ansi: [UInt32],
         cursor: UInt32? = nil, terminalBackground: UInt32? = nil, terminalForeground: UInt32? = nil) {
        let bg = NSColor(hex: background)
        let fg = NSColor(hex: text)
        self.id = id
        self.name = name
        isDark = dark
        self.background = bg
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
        // Dark themes lift the sidebar towards the text colour; light themes sink it a little.
        sidebar = bg.mixed(with: dark ? fg : NSColor.black, amount: dark ? 0.045 : 0.035)
        elevated = bg.mixed(with: dark ? fg : NSColor.white, amount: dark ? 0.08 : 0.6)
        border = fg.withAlphaComponent(dark ? 0.12 : 0.13)
        tertiaryText = fg.withAlphaComponent(0.42)
        self.warning = NSColor(hex: warning)
        self.agent = NSColor(hex: agent)
        let palette = TerminalPalette(background: terminalBackground ?? background, foreground: terminalForeground ?? text,
                                      cursor: cursor ?? accent, selection: accent, ansi: ansi)
        terminalLight = palette
        terminalDark = palette
    }

    /// Follows the system: `light` in light mode, `dark` in dark mode.
    init(automatic id: String, name: String, light: CodeTheme, dark: CodeTheme) {
        func pick(_ keyPath: KeyPath<CodeTheme, NSColor>) -> NSColor { .dynamic(light: light[keyPath: keyPath], dark: dark[keyPath: keyPath]) }
        self.id = id
        self.name = name
        isDark = nil
        background = pick(\.background); text = pick(\.text); secondaryText = pick(\.secondaryText); accent = pick(\.accent)
        addedText = pick(\.addedText); removedText = pick(\.removedText); addedBackground = pick(\.addedBackground)
        removedBackground = pick(\.removedBackground); addedHighlight = pick(\.addedHighlight); removedHighlight = pick(\.removedHighlight)
        gutter = pick(\.gutter); gutterText = pick(\.gutterText); header = pick(\.header); headerText = pick(\.headerText)
        selection = pick(\.selection); filler = pick(\.filler); separator = pick(\.separator); keyword = pick(\.keyword)
        type = pick(\.type); string = pick(\.string); comment = pick(\.comment); number = pick(\.number)
        attribute = pick(\.attribute); key = pick(\.key); sidebar = pick(\.sidebar); elevated = pick(\.elevated)
        border = pick(\.border); tertiaryText = pick(\.tertiaryText); warning = pick(\.warning); agent = pick(\.agent)
        terminalLight = light.terminalLight
        terminalDark = dark.terminalDark
    }

    /// Terminal colours for the given appearance.
    func terminalAppearance(dark systemDark: Bool, fontFamily: String?, fontSize: Double?) -> TerminalAppearance {
        let dark = isDark ?? systemDark
        let palette = dark ? terminalDark : terminalLight
        func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
        return TerminalAppearance(background: hex(palette.background), foreground: hex(palette.foreground), cursor: hex(palette.cursor),
                                  selectionBackground: hex(palette.selection), selectionForeground: hex(palette.background),
                                  palette: palette.ansi.map(hex), isDark: dark, fontFamily: fontFamily, fontSize: fontSize)
    }

    // MARK: Themes

    /// Forest's own: deep evergreen with moss and warm bark.
    static let forestNight = CodeTheme(id: "forestNight", name: "Forest Night", dark: true,
        background: 0x131C18, text: 0xDCE6DF, comment: 0x7D9187, accent: 0x4FD08B, added: 0x6FD99A, removed: 0xF0857C,
        keyword: 0x7FD3C2, type: 0xE8C47A, string: 0xA9DB8C, number: 0xE59E6D, attribute: 0xC7A6E8, key: 0x86BEEB,
        warning: 0xF2C35E, agent: 0xEE8B67,
        ansi: [0x1F2B25, 0xE5736B, 0x7FCF8F, 0xE8C46B, 0x6FA8DC, 0xC79BD8, 0x6CC5B0, 0xC9D6CD,
               0x4A5E53, 0xF08A82, 0x97E0A5, 0xF0D388, 0x8BBBE6, 0xD6B0E4, 0x86D6C2, 0xF0F5F1],
        cursor: 0x4FD08B)
    /// Forest's own light: warm paper, ink and leaf.
    static let forestDay = CodeTheme(id: "forestDay", name: "Forest Day", dark: false,
        background: 0xFAF8F2, text: 0x23302A, comment: 0x7A857E, accent: 0x1E9E5E, added: 0x1F8A4C, removed: 0xC8433A,
        keyword: 0x9B3D8F, type: 0x8A5A00, string: 0x2C7A3F, number: 0x2B55C0, attribute: 0xB4541A, key: 0x1D6FB8,
        warning: 0xB7791F, agent: 0xC9643F,
        ansi: [0x23302A, 0xC2453B, 0x2F8A4C, 0xA97A12, 0x2F6FB0, 0x8C4FA8, 0x1F8A7A, 0xD8D3C6,
               0x5D6B62, 0xD9574C, 0x3AA05C, 0xC08E1C, 0x3F82C4, 0xA062BD, 0x2AA18F, 0xFFFFFF],
        cursor: 0x1E9E5E)
    static let automatic = CodeTheme(automatic: "forest", name: "Automatic", light: forestDay, dark: forestNight)

    // Solarized as in iTerm2's built-in preset.
    static let solarizedDark = CodeTheme(id: "solarizedDark", name: "Solarized Dark", dark: true,
        background: 0x002B36, text: 0x839496, comment: 0x586E75, accent: 0x268BD2, added: 0x859900, removed: 0xDC322F,
        keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682, attribute: 0xCB4B16, key: 0x268BD2,
        warning: 0xB58900, agent: 0xCB4B16,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x335E69, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
        cursor: 0x839496)
    static let solarizedLight = CodeTheme(id: "solarizedLight", name: "Solarized Light", dark: false,
        background: 0xFDF6E3, text: 0x657B83, comment: 0x93A1A1, accent: 0x268BD2, added: 0x859900, removed: 0xDC322F,
        keyword: 0x859900, type: 0xB58900, string: 0x2AA198, number: 0xD33682, attribute: 0xCB4B16, key: 0x268BD2,
        warning: 0xB58900, agent: 0xCB4B16,
        ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
               0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3],
        cursor: 0x657B83)
    static let dracula = CodeTheme(id: "dracula", name: "Dracula", dark: true,
        background: 0x282A36, text: 0xF8F8F2, comment: 0x6272A4, accent: 0xBD93F9, added: 0x50FA7B, removed: 0xFF5555,
        keyword: 0xFF79C6, type: 0x8BE9FD, string: 0xF1FA8C, number: 0xBD93F9, attribute: 0x50FA7B, key: 0x8BE9FD,
        warning: 0xF1FA8C, agent: 0xFFB86C,
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
        cursor: 0xF8F8F2)
    static let oneDark = CodeTheme(id: "oneDark", name: "One Dark", dark: true,
        background: 0x282C34, text: 0xABB2BF, comment: 0x5C6370, accent: 0x61AFEF, added: 0x98C379, removed: 0xE06C75,
        keyword: 0xC678DD, type: 0xE5C07B, string: 0x98C379, number: 0xD19A66, attribute: 0x56B6C2, key: 0xE06C75,
        warning: 0xE5C07B, agent: 0xD19A66,
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF],
        cursor: 0x528BFF)
    static let monokai = CodeTheme(id: "monokai", name: "Monokai", dark: true,
        background: 0x272822, text: 0xF8F8F2, comment: 0x75715E, accent: 0x66D9EF, added: 0xA6E22E, removed: 0xF92672,
        keyword: 0xF92672, type: 0x66D9EF, string: 0xE6DB74, number: 0xAE81FF, attribute: 0xA6E22E, key: 0xFD971F,
        warning: 0xE6DB74, agent: 0xFD971F,
        ansi: [0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
               0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5],
        cursor: 0xF8F8F0)
    static let nord = CodeTheme(id: "nord", name: "Nord", dark: true,
        background: 0x2E3440, text: 0xD8DEE9, comment: 0x616E88, accent: 0x88C0D0, added: 0xA3BE8C, removed: 0xBF616A,
        keyword: 0x81A1C1, type: 0x8FBCBB, string: 0xA3BE8C, number: 0xB48EAD, attribute: 0xD08770, key: 0x88C0D0,
        warning: 0xEBCB8B, agent: 0xD08770,
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
        cursor: 0xD8DEE9)
    static let gruvboxDark = CodeTheme(id: "gruvboxDark", name: "Gruvbox Dark", dark: true,
        background: 0x282828, text: 0xEBDBB2, comment: 0x928374, accent: 0x83A598, added: 0xB8BB26, removed: 0xFB4934,
        keyword: 0xFB4934, type: 0xFABD2F, string: 0xB8BB26, number: 0xD3869B, attribute: 0x8EC07C, key: 0x83A598,
        warning: 0xFABD2F, agent: 0xFE8019,
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
        cursor: 0xEBDBB2)
    static let tokyoNight = CodeTheme(id: "tokyoNight", name: "Tokyo Night", dark: true,
        background: 0x1A1B26, text: 0xC0CAF5, comment: 0x565F89, accent: 0x7AA2F7, added: 0x9ECE6A, removed: 0xF7768E,
        keyword: 0xBB9AF7, type: 0x7DCFFF, string: 0x9ECE6A, number: 0xFF9E64, attribute: 0xE0AF68, key: 0x7AA2F7,
        warning: 0xE0AF68, agent: 0xFF9E64,
        ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5],
        cursor: 0xC0CAF5)
    static let catppuccinMocha = CodeTheme(id: "catppuccinMocha", name: "Catppuccin Mocha", dark: true,
        background: 0x1E1E2E, text: 0xCDD6F4, comment: 0x6C7086, accent: 0x89B4FA, added: 0xA6E3A1, removed: 0xF38BA8,
        keyword: 0xCBA6F7, type: 0xF9E2AF, string: 0xA6E3A1, number: 0xFAB387, attribute: 0x94E2D5, key: 0x89B4FA,
        warning: 0xF9E2AF, agent: 0xFAB387,
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8],
        cursor: 0xF5E0DC)
    static let catppuccinLatte = CodeTheme(id: "catppuccinLatte", name: "Catppuccin Latte", dark: false,
        background: 0xEFF1F5, text: 0x4C4F69, comment: 0x8C8FA1, accent: 0x1E66F5, added: 0x40A02B, removed: 0xD20F39,
        keyword: 0x8839EF, type: 0xDF8E1D, string: 0x40A02B, number: 0xFE640B, attribute: 0x179299, key: 0x1E66F5,
        warning: 0xDF8E1D, agent: 0xFE640B,
        ansi: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
               0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC],
        cursor: 0xDC8A78)
    static let rosePine = CodeTheme(id: "rosePine", name: "Rosé Pine", dark: true,
        background: 0x191724, text: 0xE0DEF4, comment: 0x6E6A86, accent: 0xC4A7E7, added: 0x9CCFD8, removed: 0xEB6F92,
        keyword: 0x31748F, type: 0x9CCFD8, string: 0xF6C177, number: 0xEBBCBA, attribute: 0xC4A7E7, key: 0xEBBCBA,
        warning: 0xF6C177, agent: 0xEBBCBA,
        ansi: [0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
               0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4],
        cursor: 0xE0DEF4)
    static let githubDark = CodeTheme(id: "githubDark", name: "GitHub Dark", dark: true,
        background: 0x0D1117, text: 0xE6EDF3, comment: 0x8B949E, accent: 0x58A6FF, added: 0x3FB950, removed: 0xF85149,
        keyword: 0xFF7B72, type: 0xFFA657, string: 0xA5D6FF, number: 0x79C0FF, attribute: 0xD2A8FF, key: 0x79C0FF,
        warning: 0xD29922, agent: 0xFFA657,
        ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
               0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF],
        cursor: 0x58A6FF)
    static let githubLight = CodeTheme(id: "githubLight", name: "GitHub Light", dark: false,
        background: 0xFFFFFF, text: 0x1F2328, comment: 0x6E7781, accent: 0x0969DA, added: 0x1A7F37, removed: 0xCF222E,
        keyword: 0xCF222E, type: 0x953800, string: 0x0A3069, number: 0x0550AE, attribute: 0x8250DF, key: 0x0550AE,
        warning: 0x9A6700, agent: 0xBC4C00,
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F],
        cursor: 0x0969DA)

    static let all: [CodeTheme] = [
        automatic, forestNight, forestDay, solarizedDark, solarizedLight, tokyoNight, catppuccinMocha, catppuccinLatte,
        rosePine, nord, gruvboxDark, dracula, oneDark, monokai, githubDark, githubLight,
    ]
    static let defaultID = solarizedDark.id

    static func named(_ id: String) -> CodeTheme { all.first { $0.id == id } ?? solarizedDark }

    /// The theme chosen in Settings.
    static var current: CodeTheme { named(UserDefaults.standard.string(forKey: SettingsKey.codeTheme) ?? defaultID) }
}

extension NSColor {
    /// WCAG relative luminance.
    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        func channel(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// This colour, darkened just enough for white text on it to read comfortably (contrast ≥ 4.5:1).
    var fillForWhiteText: NSColor {
        var color = self
        for _ in 0..<12 where 1.05 / (color.relativeLuminance + 0.05) < 4.5 {
            color = color.mixed(with: .black, amount: 0.12)
        }
        return color
    }

    /// Blends towards `other` in sRGB.
    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return self }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * amount,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * amount)
    }
}

// MARK: - SwiftUI access

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = CodeTheme.current
}

extension EnvironmentValues {
    /// The window's theme; set once at the root from Settings.
    var theme: CodeTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension CodeTheme {
    var canvasColor: Color { Color(nsColor: background) }
    var sidebarColor: Color { Color(nsColor: sidebar) }
    var elevatedColor: Color { Color(nsColor: elevated) }
    var borderColor: Color { Color(nsColor: border) }
    var textColor: Color { Color(nsColor: text) }
    var secondaryColor: Color { Color(nsColor: secondaryText) }
    var tertiaryColor: Color { Color(nsColor: tertiaryText) }
    var accentColor: Color { Color(nsColor: accent) }
    var addedColor: Color { Color(nsColor: addedText) }
    var removedColor: Color { Color(nsColor: removedText) }
    var warningColor: Color { Color(nsColor: warning) }
    var agentColor: Color { Color(nsColor: agent) }
    var selectionColor: Color { Color(nsColor: selection) }
    /// Fills behind white text (selected rows, highlighted items): the accent, darkened when it's too light.
    var accentFillColor: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = self.accent
            appearance.performAsCurrentDrawingAppearance { resolved = self.accent.usingColorSpace(.sRGB) ?? self.accent }
            return resolved.fillForWhiteText
        })
    }
}
