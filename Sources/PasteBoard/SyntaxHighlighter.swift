import SwiftUI

/// A tiny, dependency-free, language-agnostic syntax highlighter for code
/// previews. A single regex classifies comments, strings, numbers, and a broad
/// set of keywords; everything else keeps the default colour.
///
/// ponytail: approximate, not a real parser — it colours the common shape of
/// code across languages (no per-grammar accuracy). `#` is treated as a line
/// comment (right for Python/shell/Ruby, wrong for C `#include`); good enough
/// for a preview. Swap in tree-sitter only if per-language fidelity matters.
enum SyntaxHighlighter {
    enum Kind { case keyword, string, comment, number }

    static let keywordColor = Color(nsColor: .systemPink)
    static let stringColor  = Color(nsColor: .systemRed)
    static let commentColor = Color(nsColor: .systemGreen)
    static let numberColor  = Color(nsColor: .systemPurple)

    private static let keywords = [
        "func", "def", "fn", "function", "lambda", "return", "yield",
        "if", "else", "elif", "for", "while", "do", "switch", "case", "break",
        "continue", "guard", "defer", "where", "match", "when",
        "let", "var", "const", "val", "static", "final", "public", "private",
        "protected", "internal", "open", "abstract", "virtual", "override",
        "class", "struct", "enum", "interface", "protocol", "extension", "trait",
        "impl", "type", "typedef", "union", "namespace", "package", "module",
        "import", "from", "include", "require", "using", "export", "default",
        "async", "await", "try", "catch", "except", "finally", "throw", "throws",
        "raise", "new", "delete", "this", "self", "super", "in", "is", "as", "of",
        "and", "or", "not", "void", "int", "float", "double", "bool", "boolean",
        "char", "string", "true", "false", "nil", "null", "none", "print", "echo",
    ]

    private static let regex: NSRegularExpression = {
        let kw = keywords.joined(separator: "|")
        let pattern = #"(?<comment>//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*)|(?<string>"""[\s\S]*?"""|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`)|(?<number>\b0[xX][0-9a-fA-F]+\b|\b\d[\d_]*(?:\.\d+)?\b)|(?<keyword>\b(?:\#(kw))\b)"#
        // Pattern is a fixed constant; a failure would be a programmer error.
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Ordered, non-overlapping classified spans. Pure — the unit-test seam.
    static func tokens(in code: String) -> [(range: NSRange, kind: Kind)] {
        let ns = code as NSString
        var out: [(NSRange, Kind)] = []
        regex.enumerateMatches(in: code, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let kind: Kind
            if match.range(withName: "comment").location != NSNotFound { kind = .comment }
            else if match.range(withName: "string").location != NSNotFound { kind = .string }
            else if match.range(withName: "number").location != NSNotFound { kind = .number }
            else { kind = .keyword }
            out.append((match.range, kind))
        }
        return out
    }

    private static func color(for kind: Kind) -> Color {
        switch kind {
        case .keyword: return keywordColor
        case .string:  return stringColor
        case .comment: return commentColor
        case .number:  return numberColor
        }
    }

    // Small memo — previews re-render often and the same snippet recurs.
    private static var cache: [String: AttributedString] = [:]

    /// Syntax-coloured `AttributedString` for a code snippet. Uncoloured spans
    /// keep `.primary`.
    static func highlight(_ code: String) -> AttributedString {
        if let cached = cache[code] { return cached }
        let ns = code as NSString
        var result = AttributedString()
        var cursor = 0
        for (range, kind) in tokens(in: code) {
            if range.location > cursor {
                var plain = AttributedString(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                plain.foregroundColor = .primary
                result += plain
            }
            var token = AttributedString(ns.substring(with: range))
            token.foregroundColor = color(for: kind)
            result += token
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            var tail = AttributedString(ns.substring(from: cursor))
            tail.foregroundColor = .primary
            result += tail
        }
        if cache.count > 400 { cache.removeAll() }   // ponytail: crude cap, fine for a preview cache
        cache[code] = result
        return result
    }
}
