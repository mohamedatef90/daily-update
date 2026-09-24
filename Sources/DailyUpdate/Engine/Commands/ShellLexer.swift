import Foundation

enum ShellOperator: String, Hashable {
    case pipe = "|"
    case or = "||"
    case and = "&&"
    case semicolon = ";"
    case newline = "\n"
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
        var escaped = false

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

            if escaped {
                current.append(char)
                escaped = false
                index += 1
                continue
            }

            if char == "\\" {
                escaped = true
                index += 1
                continue
            }

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

            let quoted = inSingleQuotes || inDoubleQuotes
            if !quoted {
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
                }

                if char == ";" {
                    flushCurrent()
                    tokens.append(ShellToken(value: ";", kind: .op(.semicolon)))
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
        var single = false
        var double = false
        var escaped = false

        for scalar in command.unicodeScalars {
            let char = Character(scalar)
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if char == "'" && !double { single.toggle() }
            if char == "\"" && !single { double.toggle() }
        }
        return single || double || escaped
    }
}
