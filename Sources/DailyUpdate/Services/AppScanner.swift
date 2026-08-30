import Foundation

struct AppScanOptions {
    let developerOnly: Bool
    let scanUtilitiesFolder: Bool
}

struct InstalledAppInfo {
    let path: String
    let name: String
    let bundleID: String
    let sparkleFeed: String?
}

enum AppScanner {
    private static let appleDevBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.apple.Developer",
        "com.apple.SafariTechnologyPreview"
    ]

    private static let skipNameFragments: [String] = [
        " uninstaller", " installer", " login item", " helper", " agent",
        " updater.app", " crash handler", " quicklook"
    ]

    private static let skipBundleIDPrefixes: [String] = [
        "com.apple.", "com.microsoft.autoupdate"
    ]

    private static let developerNameKeywords: [String] = [
        "ide", "code", "editor", "terminal", "git", "docker", "studio", "dev",
        "cli", "sdk", "api", "database", "postgres", "redis", "mongo", "node",
        "python", "rust", "go ", "java", "kotlin", "swift", "xcode", "jetbrains",
        "cursor", "warp", "figma", "postman", "insomnia", "raycast", "alfred",
        "vscode", "visual studio", "neovim", "vim", "emacs", "terraform", "kubernetes",
        "lens", "dbeaver", "tableplus", "ngrok", "sublime", "zed", "nova", "tower",
        "sourcetree", "gitkraken", "fork", "iterm", "hyper", "wezterm", "alacritty",
        "antigravity", "zcode", "codex", "claude", "chatgpt", "obsidian", "linear",
        "slack", "discord", "notion", "datagrip", "pycharm", "webstorm", "goland",
        "rider", "rubymine", "phpstorm", "clion", "fleet", "android studio",
        "simulator", "charles", "proxyman", "insomnia", "hoppscotch", "postico",
        "sequel", "tableau", "docker", "orbstack", "colima", "podman", "rancher",
        "kite", "copilot", "sourcegraph", "sentry", "datadog", "vercel", "netlify",
        "heroku", "local", "mamp", "xampp", "dbeaver", "azure", "aws", "gcloud",
        "firebase", "supabase", "planetscale", "beekeeper", "dash", "paw", "rapidapi",
        "bruno", "mockoon", "stoplight", "openapi", "graphql", "redis insight",
        "mongodb compass", "mysql", "sqlite", "duckdb", "jupyter", "anaconda",
        "miniconda", "poetry", "uv ", "pnpm", "yarn", "bun", "deno", "esbuild",
        "vite", "webpack", "parcel", "tailwind", "storybook", "chromedriver",
        "playwright", "selenium", "appium", "testflight", "transporter"
    ]

    private static let developerBundleIDKeywords: [String] = [
        "jetbrains", "microsoft.vscode", "cursor", "warp", "figma", "postman",
        "insomnia", "docker", "github", "gitlab", "atlassian", "sublimetext",
        "google.antigravity", "zcode", "openai", "anthropic", "todesktop",
        "electron", "dev.", ".dev.", "studio", "terminal", "iterm", "wezterm",
        "hyper", "alacritty", "tableplus", "dbeaver", "ngrok", "raycast",
        "tower", "gitkraken", "sublimemerge", "fork", "zed", "nova", "linear",
        "slack", "discord", "notion", "obsidian", "orbstack", "colima",
        "proxyman", "charles", "paw.", "rapidapi", "bruno", "beekeeper",
        "mongodb", "redis", "planetscale", "supabase", "vercel", "netlify"
    ]

    static func discoverApps(
        in folders: [String],
        excludingPaths: Set<String>,
        excludingBundleIDs: Set<String>,
        options: AppScanOptions
    ) -> [DetectorConfig] {
        var results: [DetectorConfig] = []
        var seenPaths: Set<String> = []
        var seenBundleIDs: Set<String> = []

        for folder in folders {
            let expanded = folder.expandingTilde
            scanFolder(expanded, options: options, excludingPaths: excludingPaths,
                       excludingBundleIDs: excludingBundleIDs, results: &results,
                       seenPaths: &seenPaths, seenBundleIDs: &seenBundleIDs)

            if options.scanUtilitiesFolder {
                let utilities = (expanded as NSString).appendingPathComponent("Utilities")
                scanFolder(utilities, options: options, excludingPaths: excludingPaths,
                           excludingBundleIDs: excludingBundleIDs, results: &results,
                           seenPaths: &seenPaths, seenBundleIDs: &seenBundleIDs)
            }
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func scanFolder(
        _ folder: String,
        options: AppScanOptions,
        excludingPaths: Set<String>,
        excludingBundleIDs: Set<String>,
        results: inout [DetectorConfig],
        seenPaths: inout Set<String>,
        seenBundleIDs: inout Set<String>
    ) {
        guard FileManager.default.fileExists(atPath: folder),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }

        for entry in entries {
            guard entry.hasSuffix(".app") else { continue }
            let path = (folder as NSString).appendingPathComponent(entry)
            guard !seenPaths.contains(path), !excludingPaths.contains(path) else { continue }

            guard let info = readAppInfo(at: path) else { continue }
            guard !excludingBundleIDs.contains(info.bundleID) else { continue }
            guard !seenBundleIDs.contains(info.bundleID) else { continue }
            guard shouldInclude(info, developerOnly: options.developerOnly) else { continue }

            seenPaths.insert(path)
            seenBundleIDs.insert(info.bundleID)
            results.append(ItemBuilder.discoveredApp(info: info))
        }
    }

    static func readAppInfo(at path: String) -> InstalledAppInfo? {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let sparkleFeed = plist["SUFeedURL"] as? String

        return InstalledAppInfo(path: path, name: name, bundleID: bundleID, sparkleFeed: sparkleFeed)
    }

    static func shouldInclude(_ app: InstalledAppInfo, developerOnly: Bool) -> Bool {
        let loweredName = app.name.lowercased()
        let loweredBundle = app.bundleID.lowercased()

        if skipNameFragments.contains(where: { loweredName.contains($0) }) { return false }
        if appleDevBundleIDs.contains(app.bundleID) { return true }
        if app.sparkleFeed != nil { return true }

        if skipBundleIDPrefixes.contains(where: { loweredBundle.hasPrefix($0) }) {
            return false
        }

        if !developerOnly { return true }

        if developerNameKeywords.contains(where: { loweredName.contains($0) }) { return true }
        if developerBundleIDKeywords.contains(where: { loweredBundle.contains($0) }) { return true }

        return false
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
