import Foundation

enum ShellOperator: String, Hashable {
    case pipe = "|"
    case pipeAnd = "|&"
    case or = "||"
    case and = "&&"
    case background = "&"
    case semicolon = ";"
    case newline = "\n"
    case leftParen = "("
    case rightParen = ")"
    case leftBrace = "{"
    case rightBrace = "}"
}

struct ShellToken: Hashable {
    enum Kind: Hashable {
        case word
        case op(ShellOperator)
    }

    let value: String
    let kind: Kind

    var isWord: Bool {
        if case .word = kind { return true }
        return false
    }
}

enum ShellLexer {
    static func lex(_ command: String) -> [ShellToken] {
        var tokens: [ShellToken] = []
        var current = ""
        var inSingleQuotes = false
        var inDoubleQuotes = false

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                tokens.append(ShellToken(value: trimmed, kind: .word))
            }
            current = ""
        }

        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let char = characters[index]

            if char == "'" && !inDoubleQuotes {
                inSingleQuotes.toggle()
                index += 1
                continue
            }

            if char == "\"" && !inSingleQuotes {
                inDoubleQuotes.toggle()
                index += 1
                continue
            }

            if char == "\\", inSingleQuotes {
                current.append(char)
                index += 1
                continue
            }

            if char == "\\", inDoubleQuotes {
                let next = index + 1 < characters.count ? characters[index + 1] : Character("\0")
                if next == "\n" {
                    index += 2
                    continue
                }
                if next == "$" || next == "`" || next == "\"" || next == "\\" {
                    current.append(next)
                    index += 2
                    continue
                }
                current.append(char)
                index += 1
                continue
            }

            if char == "\\", !inSingleQuotes, !inDoubleQuotes {
                guard index + 1 < characters.count else {
                    current.append(char)
                    index += 1
                    continue
                }
                current.append(characters[index + 1])
                index += 2
                continue
            }

            let quoted = inSingleQuotes || inDoubleQuotes
            if !quoted {
                if char == "$",
                   index + 1 < characters.count,
                   characters[index + 1] == "'" {
                    let parseStart = index + 2
                    if let parsed = parseAnsiCString(characters: characters, start: parseStart) {
                        current.append(parsed.value)
                        index = parsed.endIndex + 1
                        continue
                    }
                }

                if char == "\n" {
                    flushCurrent()
                    tokens.append(ShellToken(value: "\n", kind: .op(.newline)))
                    index += 1
                    continue
                }
                if char.isWhitespace {
                    flushCurrent()
                    index += 1
                    continue
                }

                if char == "|" || char == "&" {
                    let next = index + 1 < characters.count ? characters[index + 1] : Character("\0")
                    if char == "|" && next == "|" {
                        flushCurrent()
                        tokens.append(ShellToken(value: "||", kind: .op(.or)))
                        index += 2
                        continue
                    }
                    if char == "|" && next == "&" {
                        flushCurrent()
                        tokens.append(ShellToken(value: "|&", kind: .op(.pipeAnd)))
                        index += 2
                        continue
                    }
                    if char == "&" && next == "&" {
                        flushCurrent()
                        tokens.append(ShellToken(value: "&&", kind: .op(.and)))
                        index += 2
                        continue
                    }
                    if char == "|" {
                        flushCurrent()
                        tokens.append(ShellToken(value: "|", kind: .op(.pipe)))
                        index += 1
                        continue
                    }
                    if char == "&" {
                        flushCurrent()
                        tokens.append(ShellToken(value: "&", kind: .op(.background)))
                        index += 1
                        continue
                    }
                }

                if char == ";" {
                    flushCurrent()
                    tokens.append(ShellToken(value: ";", kind: .op(.semicolon)))
                    index += 1
                    continue
                }

                if char == "(" {
                    flushCurrent()
                    tokens.append(ShellToken(value: "(", kind: .op(.leftParen)))
                    index += 1
                    continue
                }

                if char == ")" {
                    flushCurrent()
                    tokens.append(ShellToken(value: ")", kind: .op(.rightParen)))
                    index += 1
                    continue
                }

                if char == "{" {
                    flushCurrent()
                    tokens.append(ShellToken(value: "{", kind: .op(.leftBrace)))
                    index += 1
                    continue
                }

                if char == "}" {
                    flushCurrent()
                    tokens.append(ShellToken(value: "}", kind: .op(.rightBrace)))
                    index += 1
                    continue
                }
            }

            current.append(char)
            index += 1
        }

        flushCurrent()
        return tokens
    }

    static func words(from tokens: [ShellToken]) -> [String] {
        tokens.compactMap { token in
            guard token.isWord else { return nil }
            return token.value
        }
    }

    static func split(_ tokens: [ShellToken], by operators: Set<ShellOperator>) -> [[ShellToken]] {
        var groups: [[ShellToken]] = []
        var current: [ShellToken] = []

        for token in tokens {
            if case .op(let op) = token.kind, operators.contains(op) {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                continue
            }
            current.append(token)
        }

        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    static func hasUnbalancedQuotes(_ command: String) -> Bool {
        let characters = Array(command)
        var single = false
        var double = false
        var ansi = false
        var escapedOutside = false
        var escapedInDouble = false

        var index = 0
        while index < characters.count {
            let char = characters[index]

            if ansi {
                if char == "\\" {
                    index += 2
                    continue
                }
                if char == "'" {
                    ansi = false
                }
                index += 1
                continue
            }

            if single {
                if char == "'" {
                    single = false
                }
                index += 1
                continue
            }

            if double {
                if escapedInDouble {
                    escapedInDouble = false
                    index += 1
                    continue
                }
                if char == "\\" {
                    let next = index + 1 < characters.count ? characters[index + 1] : Character("\0")
                    if next == "$" || next == "`" || next == "\"" || next == "\\" || next == "\n" {
                        escapedInDouble = true
                    }
                    index += 1
                    continue
                }
                if char == "\"" {
                    double = false
                }
                index += 1
                continue
            }

            if escapedOutside {
                escapedOutside = false
                index += 1
                continue
            }

            if char == "\\" {
                escapedOutside = true
                index += 1
                continue
            }

            if char == "$",
               index + 1 < characters.count,
               characters[index + 1] == "'" {
                ansi = true
                index += 2
                continue
            }

            if char == "'" {
                single = true
                index += 1
                continue
            }

            if char == "\"" {
                double = true
            }
            index += 1
        }

        return single || double || ansi || escapedOutside
    }

    static func nestedCommands(in command: String) -> [String] {
        let characters = Array(command)
        var nested: [String] = []
        var index = 0
        var inSingle = false
        var inDouble = false
        var escaped = false
        var inAnsi = false

        while index < characters.count {
            let char = characters[index]

            if inAnsi {
                if char == "\\" {
                    index += 2
                    continue
                }
                if char == "'" {
                    inAnsi = false
                }
                index += 1
                continue
            }

            if escaped {
                escaped = false
                index += 1
                continue
            }

            if char == "\\", !inSingle {
                escaped = true
                index += 1
                continue
            }

            if char == "$",
               !inSingle,
               index + 1 < characters.count,
               characters[index + 1] == "'" {
                inAnsi = true
                index += 2
                continue
            }

            if char == "'" && !inDouble {
                inSingle.toggle()
                index += 1
                continue
            }

            if char == "\"" && !inSingle {
                inDouble.toggle()
                index += 1
                continue
            }

            if inSingle {
                index += 1
                continue
            }

            if char == "`", let captured = captureBacktickCommand(characters: characters, start: index + 1) {
                nested.append(captured.value)
                index = captured.endIndex + 1
                continue
            }

            if (char == "$" || char == "<"),
               index + 1 < characters.count,
               characters[index + 1] == "(",
               let captured = captureParenthesizedCommand(characters: characters, start: index + 2) {
                nested.append(captured.value)
                index = captured.endIndex + 1
                continue
            }

            index += 1
        }

        return nested
    }

    private static func parseAnsiCString(characters: [Character], start: Int) -> (value: String, endIndex: Int)? {
        guard start <= characters.count else { return nil }
        var index = start
        var value = ""

        while index < characters.count {
            let char = characters[index]
            if char == "'" {
                return (value, index)
            }
            if char == "\\", index + 1 < characters.count {
                let escaped = characters[index + 1]
                switch escaped {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "a": value.append("\u{07}")
                case "b": value.append("\u{08}")
                case "f": value.append("\u{0C}")
                case "v": value.append("\u{0B}")
                case "\\": value.append("\\")
                case "'": value.append("'")
                case "\"": value.append("\"")
                case "0": value.append("\0")
                case "\n":
                    break
                default:
                    value.append(escaped)
                }
                index += 2
                continue
            }
            value.append(char)
            index += 1
        }
        return nil
    }

    private static func captureBacktickCommand(characters: [Character], start: Int) -> (value: String, endIndex: Int)? {
        var index = start
        var value = ""
        var escaped = false
        while index < characters.count {
            let char = characters[index]
            if escaped {
                value.append(char)
                escaped = false
                index += 1
                continue
            }
            if char == "\\" {
                escaped = true
                index += 1
                continue
            }
            if char == "`" {
                return (value, index)
            }
            value.append(char)
            index += 1
        }
        return nil
    }

    private static func captureParenthesizedCommand(characters: [Character], start: Int) -> (value: String, endIndex: Int)? {
        var index = start
        var depth = 1
        var value = ""
        var inSingle = false
        var inDouble = false
        var escaped = false

        while index < characters.count {
            let char = characters[index]

            if escaped {
                value.append(char)
                escaped = false
                index += 1
                continue
            }

            if char == "\\", !inSingle {
                escaped = true
                value.append(char)
                index += 1
                continue
            }

            if char == "'" && !inDouble {
                inSingle.toggle()
                value.append(char)
                index += 1
                continue
            }

            if char == "\"" && !inSingle {
                inDouble.toggle()
                value.append(char)
                index += 1
                continue
            }

            if !inSingle, !inDouble {
                if char == "(" {
                    depth += 1
                    value.append(char)
                    index += 1
                    continue
                }
                if char == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (value, index)
                    }
                    value.append(char)
                    index += 1
                    continue
                }
            }

            value.append(char)
            index += 1
        }

        return nil
    }
}
