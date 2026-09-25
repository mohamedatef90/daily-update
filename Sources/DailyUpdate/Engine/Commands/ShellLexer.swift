import Foundation

enum ShellOperator: String, Hashable {
    case pipe = "|", pipeAnd = "|&", or = "||", and = "&&", background = "&"
    case semicolon = ";", newline = "\n"
    case leftParen = "(", rightParen = ")", leftBrace = "{", rightBrace = "}"
}

struct ShellToken: Hashable {
    enum Kind: Hashable { case word, op(ShellOperator) }
    let value: String
    let kind: Kind
    var hasUnquotedGlob = false
    /// Any unquoted `{` or `}` inside the word: a `{a,b}` list, a `{x..y}`
    /// range, or a zsh `{cmd …}` group whose `{` has no space after it.
    var hasUnquotedBrace = false
    /// Offset (in `value`) just past the first unquoted `)`, if any.
    var caseTerminatorEnd: Int?
    var hasUnquotedCaseTerminator: Bool { caseTerminatorEnd != nil }
    var isWord: Bool { if case .word = kind { return true }; return false }
}

enum ShellLexer {
    private struct Scan {
        var tokens: [ShellToken] = []
        var nested: [String] = []
        var invalid = false
        var end = 0
    }

    static func lex(_ command: String) -> [ShellToken] { scan(Array(command)).tokens }
    /// True for text this lexer does not model: unbalanced quotes, heredocs,
    /// ANSI-C escapes, and a `(` attached to the word before it.
    static func hasUnbalancedQuotes(_ command: String) -> Bool { scan(Array(command)).invalid }
    static func nestedCommands(in command: String) -> [String] { scan(Array(command)).nested }
    static func words(from tokens: [ShellToken]) -> [String] { tokens.filter(\.isWord).map(\.value) }

    // All consumers share this quote/comment/substitution state machine. Nested
    // shell bodies start a fresh quote context; their raw text remains in the word.
    private static func scan(_ chars: [Character], start: Int = 0, until: Character? = nil) -> Scan {
        var result = Scan()
        var index = start
        var word = ""
        var started = false
        var glob = false
        var brace = false
        var caseTerminatorEnd: Int?
        var single = false
        var double = false
        func flush() {
            if started {
                result.tokens.append(ShellToken(value: word, kind: .word, hasUnquotedGlob: glob || brace,
                    hasUnquotedBrace: brace, caseTerminatorEnd: caseTerminatorEnd))
            }
            word = ""; started = false; glob = false; brace = false; caseTerminatorEnd = nil
        }
        while index < chars.count {
            let char = chars[index]
            let next: Character = index + 1 < chars.count ? chars[index + 1] : "\0"
            if single {
                if char == "'" { single = false } else { word.append(char) }
                index += 1; continue
            }
            if char == "\\" {
                if next == "\0" { result.invalid = true; index += 1; continue }
                if !double || ["$", "`", "\"", "\\", "\n"].contains(next) {
                    if next != "\n" { word.append(next); started = true }
                    index += 2; continue
                }
                word.append(char); started = true; index += 1; continue
            }
            if char == "'", !double { single = true; started = true; index += 1; continue }
            if char == "\"" { double.toggle(); started = true; index += 1; continue }
            if !double, char == "#", !started {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if !double, char == "$", next == "'" {
                started = true
                index += 2
                var closed = false
                while index < chars.count {
                    if chars[index] == "'" { closed = true; index += 1; break }
                    if chars[index] == "\\" {
                        // ANSI-C escape decoding is intentionally unsupported.
                        result.invalid = true
                        word.append(chars[index])
                        index += 1
                        if index < chars.count { word.append(chars[index]); index += 1 }
                    } else { word.append(chars[index]); index += 1 }
                }
                if !closed { result.invalid = true }
                continue
            }
            if char == "`" {
                let begin = index
                index += 1
                let body = index
                while index < chars.count, chars[index] != "`" {
                    if chars[index] == "\\", index + 1 < chars.count { index += 1 }
                    index += 1
                }
                if index == chars.count { result.invalid = true }
                result.nested.append(String(chars[body..<index]))
                if index < chars.count { index += 1 }
                word += String(chars[begin..<index]); started = true
                continue
            }
            if next == "(", char == "$" || (!double && (char == "<" || char == ">" || char == "=")) {
                let body = scan(chars, start: index + 2, until: ")")
                result.nested.append(String(chars[(index + 2)..<body.end]))
                result.invalid = result.invalid || body.invalid
                let end = min(body.end + 1, chars.count)
                word += String(chars[index..<end]); started = true
                index = end; continue
            }
            if !double {
                if char == until, char != "}" || !started { flush(); result.end = index; return result }
                if char == "<", next == "<" {
                    let hereString = index + 2 < chars.count && chars[index + 2] == "<"
                    if !hereString { result.invalid = true }
                    word += hereString ? "<<<" : "<<"; started = true
                    index += hereString ? 3 : 2; continue
                }
                if char == "(" || (char == "{" && !started && (next.isWhitespace || next == "\0")) {
                    // zsh reads `(` attached to a word as a glob group (`br(e)w`,
                    // `sud(o|x)`). Only an empty `()` ending a function name is modelled.
                    if char == "(", started, !endsFunctionName(chars, at: index) { result.invalid = true }
                    flush()
                    let closing: Character = char == "(" ? ")" : "}"
                    let body = scan(chars, start: index + 1, until: closing)
                    result.tokens.append(ShellToken(value: String(char), kind: .op(char == "(" ? .leftParen : .leftBrace)))
                    result.tokens += body.tokens
                    result.tokens.append(ShellToken(value: String(closing), kind: .op(char == "(" ? .rightParen : .rightBrace)))
                    result.nested.append(String(chars[(index + 1)..<body.end]))
                    // zsh reads `(…)(…)` as a glob with qualifiers, e.g. `(e:'cmd':)`.
                    let attached = char == "(" && body.end + 1 < chars.count && chars[body.end + 1] == "("
                    result.invalid = result.invalid || body.invalid || attached
                    index = min(body.end + 1, chars.count); continue
                }
                if char == "\n" { flush(); result.tokens.append(ShellToken(value: "\n", kind: .op(.newline))); index += 1; continue }
                if char.isWhitespace { flush(); index += 1; continue }
                let pair = String([char, next])
                if let op = ShellOperator(rawValue: pair), [.and, .or, .pipeAnd].contains(op) {
                    flush(); result.tokens.append(ShellToken(value: pair, kind: .op(op))); index += 2; continue
                }
                if let op = ShellOperator(rawValue: String(char)), [.pipe, .background, .semicolon].contains(op) {
                    flush(); result.tokens.append(ShellToken(value: String(char), kind: .op(op))); index += 1; continue
                }
                if ["*", "?", "["].contains(char) { glob = true }
                if char == "$", next == "{" {
                    // `${…}` is parameter expansion, not a brace list or group. Its body
                    // may hold only plain parameter syntax and nested `${…}`; a quote,
                    // escape, substitution or zsh `(flags)` is not modelled.
                    var depth = 0
                    while index < chars.count {
                        let part = chars[index]
                        if part == "$", index + 1 < chars.count, chars[index + 1] == "{" {
                            word += "${"; index += 2; depth += 1; continue
                        }
                        if part == "}" { word.append(part); index += 1; depth -= 1; if depth == 0 { break }; continue }
                        guard isParameterCharacter(part) else { break }
                        word.append(part); index += 1
                    }
                    if depth != 0 { result.invalid = true }
                    started = true; continue
                }
                // An empty `{}` stays literal (`xargs -I{}`, `find -exec … {}`).
                if char == "{", next == "}" { word += "{}"; started = true; index += 2; continue }
                // zsh expands `{a,b}` and `{x..y}`, and runs `{cmd …}` as a group.
                if char == "{" || char == "}" { brace = true }
                if char == ")", caseTerminatorEnd == nil { caseTerminatorEnd = word.count + 1 }
            }
            word.append(char); started = true; index += 1
        }
        flush()
        result.invalid = result.invalid || single || double || until != nil
        result.end = index
        return result
    }

    private static func isParameterCharacter(_ char: Character) -> Bool {
        (char.isASCII && (char.isLetter || char.isNumber)) || "_#%:/?=+-.,@*^~!".contains(char)
    }

    private static func endsFunctionName(_ chars: [Character], at index: Int) -> Bool {
        guard index + 1 < chars.count, chars[index + 1] == ")" else { return false }
        guard index + 2 < chars.count else { return true }
        let after = chars[index + 2]
        return after.isWhitespace || ["{", ";", "&", "|"].contains(after)
    }

    static func split(_ tokens: [ShellToken], by operators: Set<ShellOperator>) -> [[ShellToken]] {
        var groups: [[ShellToken]] = []
        var current: [ShellToken] = []
        var depth = 0
        for token in tokens {
            if case .op(let op) = token.kind {
                if depth == 0, operators.contains(op) {
                    if !current.isEmpty { groups.append(current); current = [] }
                    continue
                }
                if op == .leftParen || op == .leftBrace { depth += 1 }
                if op == .rightParen || op == .rightBrace { depth -= 1 }
            }
            current.append(token)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
