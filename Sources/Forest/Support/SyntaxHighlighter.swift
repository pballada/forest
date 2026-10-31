import AppKit

/// A small, line-local highlighter. It doesn't parse; it recognises comments, strings, numbers,
/// keywords and type-like names well enough to make diffs easier to scan, and it is cheap enough
/// to run on every visible line as it's drawn.
struct SyntaxHighlighter {
    enum Token { case keyword, type, string, comment, number, attribute, key }

    struct Language {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComments = true
        var quotes: Set<UInt16> = [34, 39]  // " '
        var capitalizedTypes = true
        var jsonKeys = false
    }

    let language: Language

    init?(path: String) {
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()
        guard let language = Self.language(forExtension: ext, name: name) else { return nil }
        self.language = language
    }

    static func language(forExtension ext: String, name: String) -> Language? {
        switch ext {
        case "swift": Language(keywords: swift)
        case "m", "mm", "h", "c", "cc", "cpp", "hpp", "cxx": Language(keywords: c)
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": Language(keywords: javascript, quotes: [34, 39, 96])
        case "java", "kt", "kts", "scala", "cs", "dart", "groovy", "gradle": Language(keywords: java)
        case "go": Language(keywords: go, quotes: [34, 39, 96])
        case "rs": Language(keywords: rust, quotes: [34])
        case "py", "pyi": Language(keywords: python, lineComments: ["#"], blockComments: false)
        case "rb", "rake": Language(keywords: ruby, lineComments: ["#"], blockComments: false)
        case "sh", "bash", "zsh", "fish": Language(keywords: shell, lineComments: ["#"], blockComments: false, capitalizedTypes: false)
        case "yml", "yaml", "toml", "ini", "cfg", "conf": Language(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"],
                                                                     blockComments: false, capitalizedTypes: false, jsonKeys: true)
        case "json", "resolved", "jsonc", "xcstrings": Language(keywords: ["true", "false", "null"], lineComments: ["//"], quotes: [34],
                                                                  capitalizedTypes: false, jsonKeys: true)
        case "pbxproj", "xcconfig", "strings", "entitlements": Language(keywords: ["isa", "YES", "NO"], quotes: [34], capitalizedTypes: false)
        case "css", "scss", "less": Language(keywords: ["important", "media", "import", "from", "to"], capitalizedTypes: false)
        case "sql": Language(keywords: sql, lineComments: ["--"], capitalizedTypes: false)
        case "html", "xml", "plist", "storyboard", "xib", "svg", "vue":
            Language(keywords: [], lineComments: [], blockComments: false, quotes: [34, 39], capitalizedTypes: false)
        default:
            switch name {
            case "Makefile", "Dockerfile", "Podfile", "Gemfile", "Brewfile", "Fastfile": Language(keywords: ruby.union(shell), lineComments: ["#"], blockComments: false)
            case ".gitignore", ".gitattributes", ".env": Language(keywords: [], lineComments: ["#"], blockComments: false, quotes: [], capitalizedTypes: false)
            default: nil
            }
        }
    }

    /// Token ranges (UTF-16) for one line of display text.
    func tokens(in text: String) -> [(NSRange, Token)] {
        let s = Array(text.utf16)
        var result: [(NSRange, Token)] = []
        var i = 0
        let n = s.count

        // Continuation lines of C-style block comments (` * foo`, ` */`).
        var firstNonSpace = 0
        while firstNonSpace < n, s[firstNonSpace] == 32 || s[firstNonSpace] == 9 { firstNonSpace += 1 }
        if language.blockComments, firstNonSpace < n, s[firstNonSpace] == 42,
           firstNonSpace + 1 >= n || s[firstNonSpace + 1] == 32 || s[firstNonSpace + 1] == 47 {
            return [(NSRange(location: firstNonSpace, length: n - firstNonSpace), .comment)]
        }

        func starts(with prefix: String, at index: Int) -> Bool {
            let p = Array(prefix.utf16)
            guard index + p.count <= n else { return false }
            for k in 0..<p.count where s[index + k] != p[k] { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }

        while i < n {
            let c = s[i]
            if let comment = language.lineComments.first(where: { starts(with: $0, at: i) }) {
                // `#` only starts a comment at a word boundary (so `#if`/`a#b` aren't comments in shell-like files).
                if comment != "#" || i == 0 || s[i - 1] == 32 || s[i - 1] == 9 {
                    result.append((NSRange(location: i, length: n - i), .comment))
                    break
                }
            }
            if language.blockComments, starts(with: "/*", at: i) {
                var j = i + 2
                while j < n, !starts(with: "*/", at: j) { j += 1 }
                j = min(n, j + 2)
                result.append((NSRange(location: i, length: j - i), .comment))
                i = j
                continue
            }
            if language.quotes.contains(c) {
                var j = i + 1
                while j < n, s[j] != c {
                    if s[j] == 92 { j += 1 }  // backslash escape
                    j += 1
                }
                j = min(n, j + 1)
                var kind = Token.string
                if language.jsonKeys {
                    var k = j
                    while k < n, s[k] == 32 { k += 1 }
                    if k < n, s[k] == 58 { kind = .key }  // ':'
                }
                result.append((NSRange(location: i, length: j - i), kind))
                i = j
                continue
            }
            if c >= 48 && c <= 57, i == 0 || !isIdent(s[i - 1]) {
                var j = i + 1
                while j < n, isIdent(s[j]) || s[j] == 46 { j += 1 }
                // Only real numeric literals (1, 2.5, 0xFF, 1_000), not hex object IDs like 4CFFABDC…
                let token = s[i..<j]
                let isHex = token.count > 2 && s[i] == 48 && (s[i + 1] == 120 || s[i + 1] == 88)
                if isHex || token.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 }) {
                    result.append((NSRange(location: i, length: j - i), .number))
                }
                i = j
                continue
            }
            if (c == 64 || c == 35), i + 1 < n, isIdentStart(s[i + 1]) {  // @attribute, #directive
                var j = i + 1
                while j < n, isIdent(s[j]) { j += 1 }
                result.append((NSRange(location: i, length: j - i), .attribute))
                i = j
                continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdent(s[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(s[i..<j]), count: j - i)
                if language.keywords.contains(word) {
                    result.append((NSRange(location: i, length: j - i), .keyword))
                } else if language.jsonKeys, j < n, s[j] == 58, language.quotes.count < 3 {
                    result.append((NSRange(location: i, length: j - i), .key))  // yaml `key:`
                } else if language.capitalizedTypes, c >= 65 && c <= 90, j - i > 1 {
                    result.append((NSRange(location: i, length: j - i), .type))
                }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    static func color(for token: Token) -> NSColor {
        switch token {
        case .keyword: DiffPalette.keyword
        case .type: DiffPalette.type
        case .string: DiffPalette.string
        case .comment: DiffPalette.comment
        case .number: DiffPalette.number
        case .attribute: DiffPalette.attribute
        case .key: DiffPalette.key
        }
    }

    // MARK: - Keyword sets

    static let swift: Set<String> = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "convenience", "default", "defer", "deinit", "didSet", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
        "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "lazy", "let",
        "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
        "true", "try", "typealias", "var", "weak", "unowned", "where", "while", "willSet", "consuming", "borrowing", "sending", "package"]
    static let c: Set<String> = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
        "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "class", "namespace", "template", "typename", "public",
        "private", "protected", "virtual", "override", "new", "delete", "nullptr", "true", "false", "this", "using", "nil", "YES", "NO",
        "self", "super", "id", "instancetype", "nonatomic", "strong", "weak", "readonly", "copy", "assign", "bool", "BOOL", "constexpr"]
    static let javascript: Set<String> = ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof",
        "interface", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof",
        "undefined", "var", "void", "while", "yield", "enum", "implements", "private", "public", "protected", "readonly", "as", "keyof"]
    static let java: Set<String> = ["abstract", "boolean", "break", "case", "catch", "class", "const", "continue", "data", "default", "do",
        "else", "enum", "extends", "false", "final", "finally", "for", "fun", "if", "implements", "import", "in", "instanceof",
        "interface", "is", "new", "null", "object", "override", "package", "private", "protected", "public", "return", "static",
        "super", "switch", "this", "throw", "throws", "true", "try", "val", "var", "void", "when", "while", "suspend", "async", "await"]
    static let go: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch",
        "true", "type", "var"]
    static let rust: Set<String> = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
    static let python: Set<String> = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
        "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or",
        "pass", "raise", "return", "True", "try", "while", "with", "yield", "self", "match", "case"]
    static let ruby: Set<String> = ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end",
        "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self",
        "super", "then", "true", "undef", "unless", "until", "when", "while", "yield", "require", "lane", "pod", "target"]
    static let shell: Set<String> = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
        "function", "return", "local", "export", "set", "unset", "echo", "exit", "source", "readonly", "shift", "true", "false"]
    static let sql: Set<String> = ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
        "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "and", "or", "not", "null", "as", "order", "by",
        "group", "having", "limit", "primary", "key", "references", "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
        "SET", "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "INDEX", "JOIN", "LEFT", "ON", "AND", "OR", "NOT", "NULL", "AS", "ORDER",
        "BY", "GROUP", "LIMIT", "PRIMARY", "KEY", "REFERENCES"]
}
