import Foundation

struct CommandSpec: Codable, Hashable {
    let executablePath: String
    let arguments: [String]

    var displayString: String {
        ([executablePath] + arguments).map(ShellEscaping.quote).joined(separator: " ")
    }
}
