import Foundation

/// Insertion-ordered string-keyed map. Setting an existing key replaces its value (last one wins),
/// so duplicate keys in a document can never crash the parser.
struct YAMLMap: Equatable {
    private(set) var keys: [String] = []
    private(set) var values: [String: YAMLNode] = [:]

    subscript(key: String) -> YAMLNode? {
        values[key]
    }

    mutating func set(_ key: String, _ value: YAMLNode) {
        if values[key] == nil {
            keys.append(key)
        }
        values[key] = value
    }

    var entries: [(key: String, value: YAMLNode)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }
}

indirect enum YAMLNode: Equatable {
    case null
    case scalar(String)
    case list([YAMLNode])
    case map(YAMLMap)

    subscript(key: String) -> YAMLNode? {
        if case .map(let map) = self { return map[key] }
        return nil
    }

    var string: String? {
        if case .scalar(let value) = self { return value }
        return nil
    }

    var list: [YAMLNode]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var map: YAMLMap? {
        if case .map(let map) = self { return map }
        return nil
    }

    /// Returns a copy of the tree with `transform` applied to every scalar value (keys are untouched).
    func mapScalars(_ transform: (String) -> String) -> YAMLNode {
        switch self {
        case .null:
            return .null
        case .scalar(let value):
            return .scalar(transform(value))
        case .list(let items):
            return .list(items.map { $0.mapScalars(transform) })
        case .map(let map):
            var copy = YAMLMap()
            for (key, value) in map.entries {
                copy.set(key, value.mapScalars(transform))
            }
            return .map(copy)
        }
    }
}

/// A dependency-free parser for the YAML subset used by Compose files:
/// block maps and lists at any indentation width, quoted and plain scalars, quote-aware comments,
/// single-line flow lists/maps (`[a, b]`, `{a: b}`), block scalars (`|`, `>`), and
/// anchors / aliases / merge keys (`&x`, `*x`, `<<: *x`).
///
/// Not supported: multi-document streams, tags, complex keys.
enum MiniYAML {
    static func parse(_ text: String) -> YAMLNode {
        var parser = Parser(text: text)
        return parser.parseDocument()
    }

    // MARK: - Lexical helpers (shared with tests)

    /// Removes a trailing `# comment`. A `#` only starts a comment at the beginning of the line
    /// or after whitespace, and never inside quotes — so `image: repo#tag` and `"a # b"` survive.
    static func stripComment(_ line: String) -> String {
        let chars = Array(line)
        var result = ""
        var quote: Character? = nil
        var escaped = false
        var index = 0

        while index < chars.count {
            let ch = chars[index]
            if let active = quote {
                result.append(ch)
                if active == "\"" {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        quote = nil
                    }
                } else if ch == "'" {
                    // `''` inside single quotes is an escaped quote, not the end of the scalar.
                    if index + 1 < chars.count, chars[index + 1] == "'" {
                        result.append("'")
                        index += 1
                    } else {
                        quote = nil
                    }
                }
                index += 1
                continue
            }

            let previous: Character? = index > 0 ? chars[index - 1] : nil
            if ch == "#", previous == nil || previous == " " || previous == "\t" {
                break
            }
            if (ch == "\"" || ch == "'"), opensQuote(after: previous) {
                quote = ch
            }
            result.append(ch)
            index += 1
        }
        return result
    }

    /// A quote character only opens a quoted scalar at the start of a token.
    /// This keeps apostrophes in plain text (`it's`) from being treated as quotes.
    private static func opensQuote(after previous: Character?) -> Bool {
        guard let previous else { return true }
        return previous == " " || previous == "\t" || previous == "[" || previous == "{" || previous == "," || previous == ":"
    }

    /// Splits `key: value` at the first `:` that is outside quotes and followed by whitespace or end of line.
    static func splitKeyValue(_ text: String) -> (key: String, value: String)? {
        if text.hasPrefix("[") || text.hasPrefix("{") { return nil }
        let chars = Array(text)
        var quote: Character? = nil
        var escaped = false
        var index = 0

        while index < chars.count {
            let ch = chars[index]
            if let active = quote {
                if active == "\"" {
                    if escaped {
                        escaped = false
                    } else if ch == "\\" {
                        escaped = true
                    } else if ch == "\"" {
                        quote = nil
                    }
                } else if ch == "'" {
                    if index + 1 < chars.count, chars[index + 1] == "'" {
                        index += 1
                    } else {
                        quote = nil
                    }
                }
            } else if (ch == "\"" || ch == "'"), opensQuote(after: index > 0 ? chars[index - 1] : nil) {
                quote = ch
            } else if ch == ":" {
                let atEnd = index == chars.count - 1
                if atEnd || chars[index + 1] == " " || chars[index + 1] == "\t" {
                    let key = unquote(String(chars[0..<index]).trimmingCharacters(in: .whitespaces))
                    guard !key.isEmpty else { return nil }
                    let value = atEnd ? "" : String(chars[(index + 1)...]).trimmingCharacters(in: .whitespaces)
                    return (key, value)
                }
            }
            index += 1
        }
        return nil
    }

    /// Removes surrounding quotes and processes escapes.
    static func unquote(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        if first == "'" && last == "'" {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if first == "\"" && last == "\"" {
            var result = ""
            var iterator = text.dropFirst().dropLast().makeIterator()
            while let ch = iterator.next() {
                guard ch == "\\" else {
                    result.append(ch)
                    continue
                }
                guard let next = iterator.next() else {
                    result.append("\\")
                    break
                }
                switch next {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "0": result.append("\0")
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                default:
                    result.append("\\")
                    result.append(next)
                }
            }
            return result
        }
        return text
    }

    /// Number of unclosed `[` / `{` outside quotes.
    static func flowDepth(_ text: String) -> Int {
        var depth = 0
        var quote: Character? = nil
        var previous: Character? = nil
        for ch in text {
            if let active = quote {
                if ch == active && previous != "\\" { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "[" || ch == "{" {
                depth += 1
            } else if ch == "]" || ch == "}" {
                depth -= 1
            }
            previous = ch
        }
        return depth
    }

    /// Splits a flow collection body on commas that are outside quotes and nested brackets.
    static func splitFlowItems(_ body: String) -> [String] {
        var items: [String] = []
        var current = ""
        var depth = 0
        var quote: Character? = nil
        var previous: Character? = nil

        for ch in body {
            if let active = quote {
                current.append(ch)
                if ch == active && previous != "\\" { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "[" || ch == "{" {
                depth += 1
                current.append(ch)
            } else if ch == "]" || ch == "}" {
                depth -= 1
                current.append(ch)
            } else if ch == "," && depth == 0 {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            items.append(tail)
        }
        return items
    }

    // MARK: - Parser

    private struct Line {
        var indent: Int
        var text: String
        let rawIndex: Int
    }

    private struct Parser {
        private var rawLines: [String] = []
        private var lines: [Line] = []
        private var position = 0
        private var anchors: [String: YAMLNode] = [:]

        init(text: String) {
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            for (index, original) in normalized.components(separatedBy: "\n").enumerated() {
                let raw = Self.expandLeadingTabs(original)
                rawLines.append(raw)
                let indent = raw.prefix { $0 == " " }.count
                let content = MiniYAML.stripComment(String(raw.dropFirst(indent)))
                    .trimmingCharacters(in: .whitespaces)
                if content.isEmpty || content == "---" || content == "..." || content.hasPrefix("%") {
                    continue
                }
                lines.append(Line(indent: indent, text: content, rawIndex: index))
            }
        }

        /// YAML forbids tabs for indentation, but hand-edited files contain them; treat one tab as two spaces.
        private static func expandLeadingTabs(_ line: String) -> String {
            var prefix = ""
            var rest = Substring(line)
            while let first = rest.first, first == " " || first == "\t" {
                prefix += first == "\t" ? "  " : " "
                rest = rest.dropFirst()
            }
            return prefix + rest
        }

        mutating func parseDocument() -> YAMLNode {
            guard !lines.isEmpty else { return .null }
            return parseBlock(indent: lines[0].indent)
        }

        private func isListItem(_ text: String) -> Bool {
            text == "-" || text.hasPrefix("- ")
        }

        private mutating func parseBlock(indent: Int) -> YAMLNode {
            guard position < lines.count else { return .null }
            let line = lines[position]
            if isListItem(line.text) {
                return parseList(indent: indent)
            }
            if MiniYAML.splitKeyValue(line.text) != nil {
                return parseMap(indent: indent)
            }
            position += 1
            return parseInline(completeFlow(line.text))
        }

        private mutating func parseMap(indent: Int) -> YAMLNode {
            var map = YAMLMap()

            while position < lines.count {
                let line = lines[position]
                if line.indent < indent { break }
                if line.indent > indent {
                    // Stray continuation line (e.g. a multi-line plain scalar): skip it.
                    position += 1
                    continue
                }
                if isListItem(line.text) { break }
                guard let (key, rawValue) = MiniYAML.splitKeyValue(line.text) else {
                    position += 1
                    continue
                }
                position += 1
                let value = parseValue(rawValue, parentIndent: indent, rawIndex: line.rawIndex)

                if key == "<<" {
                    let sources: [YAMLNode] = value.list ?? [value]
                    for source in sources {
                        guard let sourceMap = source.map else { continue }
                        for (mergeKey, mergeValue) in sourceMap.entries where map[mergeKey] == nil {
                            map.set(mergeKey, mergeValue)
                        }
                    }
                } else {
                    map.set(key, value)
                }
            }
            return .map(map)
        }

        private mutating func parseList(indent: Int) -> YAMLNode {
            var items: [YAMLNode] = []

            while position < lines.count {
                let line = lines[position]
                guard line.indent == indent, isListItem(line.text) else { break }

                let afterDash = line.text.dropFirst()
                let rest = String(afterDash.drop { $0 == " " })
                let offset = indent + 1 + (afterDash.count - rest.count)

                if rest.isEmpty {
                    position += 1
                    if position < lines.count, lines[position].indent > indent {
                        items.append(parseBlock(indent: lines[position].indent))
                    } else {
                        items.append(.null)
                    }
                } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    // `- |` : a block scalar as a list item (e.g. a multi-line shell script).
                    position += 1
                    items.append(parseBlockScalar(header: rest, parentIndent: indent, rawIndex: line.rawIndex))
                } else if isListItem(rest) {
                    lines[position] = Line(indent: offset, text: rest, rawIndex: line.rawIndex)
                    items.append(parseList(indent: offset))
                } else if MiniYAML.splitKeyValue(rest) != nil {
                    // `- key: value` starts an inline map whose keys are aligned with `key`.
                    lines[position] = Line(indent: offset, text: rest, rawIndex: line.rawIndex)
                    items.append(parseMap(indent: offset))
                } else {
                    position += 1
                    items.append(parseInline(completeFlow(rest)))
                }
            }
            return .list(items)
        }

        private mutating func parseValue(_ rawValue: String, parentIndent: Int, rawIndex: Int) -> YAMLNode {
            var text = rawValue.trimmingCharacters(in: .whitespaces)
            var anchor: String? = nil
            if text.hasPrefix("&") {
                let token = text.prefix { $0 != " " }
                anchor = String(token.dropFirst())
                text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespaces)
            }

            let node: YAMLNode
            if text.isEmpty {
                if position < lines.count {
                    let next = lines[position]
                    if next.indent > parentIndent {
                        node = parseBlock(indent: next.indent)
                    } else if next.indent == parentIndent && isListItem(next.text) {
                        // YAML allows a list at the same indentation as its parent key.
                        node = parseList(indent: parentIndent)
                    } else {
                        node = .null
                    }
                } else {
                    node = .null
                }
            } else if text.hasPrefix("|") || text.hasPrefix(">") {
                node = parseBlockScalar(header: text, parentIndent: parentIndent, rawIndex: rawIndex)
            } else {
                node = parseInline(completeFlow(text))
            }

            if let anchor, !anchor.isEmpty {
                anchors[anchor] = node
            }
            return node
        }

        /// A flow collection may span several lines (`command: [` … `]`). When `text` opens more
        /// brackets than it closes, the following lines are appended until it is balanced.
        private mutating func completeFlow(_ text: String) -> String {
            guard text.hasPrefix("[") || text.hasPrefix("{") else { return text }
            var result = text
            while MiniYAML.flowDepth(result) > 0, position < lines.count {
                result += " " + lines[position].text
                position += 1
            }
            return result
        }

        private mutating func parseBlockScalar(header: String, parentIndent: Int, rawIndex: Int) -> YAMLNode {
            let folded = header.hasPrefix(">")
            var collected: [String] = []
            var lastRawIndex = rawIndex
            var cursor = rawIndex + 1

            while cursor < rawLines.count {
                let raw = rawLines[cursor]
                let isBlank = raw.trimmingCharacters(in: .whitespaces).isEmpty
                let indent = raw.prefix { $0 == " " }.count
                if !isBlank && indent <= parentIndent { break }
                collected.append(raw)
                if !isBlank { lastRawIndex = cursor }
                cursor += 1
            }

            while position < lines.count, lines[position].rawIndex <= lastRawIndex {
                position += 1
            }

            // Drop trailing blank lines and remove the common indentation.
            while let last = collected.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                collected.removeLast()
            }
            let blockIndent = collected
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { $0.prefix { $0 == " " }.count }
                .min() ?? 0
            let body = collected.map { line -> String in
                line.count >= blockIndent ? String(line.dropFirst(blockIndent)) : ""
            }

            if folded {
                var result = ""
                for line in body {
                    if line.isEmpty {
                        result += "\n"
                    } else if result.isEmpty || result.hasSuffix("\n") {
                        result += line
                    } else {
                        result += " " + line
                    }
                }
                return .scalar(result)
            }
            return .scalar(body.joined(separator: "\n"))
        }

        private func parseInline(_ rawText: String) -> YAMLNode {
            let text = rawText.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return .null }

            if text.hasPrefix("*") {
                let name = String(text.dropFirst())
                return anchors[name] ?? .null
            }
            if text.hasPrefix("[") && text.hasSuffix("]") {
                let body = String(text.dropFirst().dropLast())
                return .list(MiniYAML.splitFlowItems(body).map { parseInline($0) })
            }
            if text.hasPrefix("{") && text.hasSuffix("}") {
                var map = YAMLMap()
                for item in MiniYAML.splitFlowItems(String(text.dropFirst().dropLast())) {
                    if let (key, value) = MiniYAML.splitKeyValue(item) {
                        map.set(key, parseInline(value))
                    } else {
                        map.set(MiniYAML.unquote(item), .null)
                    }
                }
                return .map(map)
            }

            let isQuoted = (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2)
                || (text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2)
            if !isQuoted, text == "~" || text.lowercased() == "null" {
                return .null
            }
            return .scalar(MiniYAML.unquote(text))
        }
    }
}
