import Foundation

/// POSIX shell word splitting and quoting.
///
/// Every command Vessel runs is executed with an argument vector (never through `sh -c`),
/// so quoting is only needed in two places: rendering a command for display / copy-paste,
/// and handing a command line to Terminal.app.
enum ShellWords {
    private static let safeCharacters = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@%+,")

    /// Quotes a single argument so that a POSIX shell reads it back as exactly `argument`.
    static func quote(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins an argument vector into a single, safely quoted command line.
    static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    /// Splits a command line into words, honouring single quotes, double quotes and backslash escapes.
    /// An unterminated quote consumes the rest of the input (the same lenient behaviour as most shells' editors).
    static func split(_ commandLine: String) -> [String] {
        var words: [String] = []
        var current = ""
        var hasWord = false

        enum Mode { case plain, single, double }
        var mode = Mode.plain
        var iterator = commandLine.makeIterator()

        while let ch = iterator.next() {
            switch mode {
            case .plain:
                if ch == "'" {
                    mode = .single
                    hasWord = true
                } else if ch == "\"" {
                    mode = .double
                    hasWord = true
                } else if ch == "\\" {
                    if let next = iterator.next() {
                        if next != "\n" { current.append(next) }
                        hasWord = true
                    }
                } else if ch == " " || ch == "\t" || ch == "\n" {
                    if hasWord {
                        words.append(current)
                        current = ""
                        hasWord = false
                    }
                } else {
                    current.append(ch)
                    hasWord = true
                }
            case .single:
                if ch == "'" {
                    mode = .plain
                } else {
                    current.append(ch)
                }
            case .double:
                if ch == "\"" {
                    mode = .plain
                } else if ch == "\\" {
                    if let next = iterator.next() {
                        // Inside double quotes a backslash only escapes these characters.
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                        } else if next != "\n" {
                            current.append("\\")
                            current.append(next)
                        }
                    }
                } else {
                    current.append(ch)
                }
            }
        }

        if hasWord {
            words.append(current)
        }
        return words
    }

    /// Renders `text` as an AppleScript string literal (including the surrounding quotes).
    static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
