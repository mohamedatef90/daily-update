import Foundation

enum FreshnessService {
    /// Refresh Homebrew metadata once per check so cask and formula comparisons use
    /// current tap data. Network failures are intentionally non-fatal.
    static func refreshPackageMetadata() async -> Bool {
        let result = await ShellRunner.run(
            "command -v brew >/dev/null 2>&1 && brew update --quiet",
            timeout: 120
        )
        return result.succeeded
    }
}
