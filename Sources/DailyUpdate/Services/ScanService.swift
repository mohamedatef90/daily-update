import AppKit
import Foundation

enum FolderPicker {
    @MainActor
    static func pickFolder(message: String = "Choose a folder", defaultURL: URL? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Select"
        if let defaultURL {
            panel.directoryURL = defaultURL
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

enum AppDetectMode: String, CaseIterable, Identifiable {
    case applicationFolder
    case script

    var id: String { rawValue }

    var label: String {
        switch self {
        case .applicationFolder: return "Applications Folder"
        case .script: return "Terminal Script"
        }
    }
}

enum ItemBuilder {
    static func makeID(prefix: String = "user") -> String {
        "\(prefix)-\(UUID().uuidString.lowercased().prefix(8))"
    }

    static func appFromFolder(name: String, appName: String, appFolders: [String], checkCommand: String?, installCommand: String? = nil, updateCommand: String, description: String?) -> DetectorConfig {
        let folders = appFolders.map { $0.expandingTilde }
        let paths = folders.map { "\($0)/\(appName).app" }
        let versionCommand = """
        for d in \(folders.map { "\"\($0)\"" }.joined(separator: " ")); do if [ -d "$d/\(appName).app" ]; then /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$d/\(appName).app/Contents/Info.plist" 2>/dev/null && exit 0; fi; done
        """

        return DetectorConfig(
            id: makeID(),
            name: name,
            category: .app,
            description: description,
            source: .user,
            detect: DetectRule(type: .app, paths: paths, command: nil, appName: appName),
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }

    static func appFromScript(name: String, detectScript: String, versionCommand: String?, checkCommand: String?, installCommand: String? = nil, updateCommand: String, description: String?) -> DetectorConfig {
        DetectorConfig(
            id: makeID(),
            name: name,
            category: .app,
            description: description,
            source: .user,
            detect: DetectRule(type: .command, paths: nil, command: detectScript, appName: nil),
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }

    static func cli(name: String, commandName: String, checkCommand: String?, installCommand: String? = nil, updateCommand: String, description: String?) -> DetectorConfig {
        DetectorConfig(
            id: makeID(),
            name: name,
            category: .cli,
            description: description,
            source: .user,
            detect: DetectRule(type: .command, paths: nil, command: "command -v \(commandName) >/dev/null 2>&1", appName: nil),
            versionCommand: "\(commandName) --version 2>/dev/null | head -1",
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }

    static func cliFromScript(name: String, detectScript: String, versionCommand: String?, checkCommand: String?, installCommand: String? = nil, updateCommand: String, description: String?) -> DetectorConfig {
        DetectorConfig(
            id: makeID(),
            name: name,
            category: .cli,
            description: description,
            source: .user,
            detect: DetectRule(type: .command, paths: nil, command: detectScript, appName: nil),
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }

    static func repo(name: String, path: String, installCommand: String? = nil, description: String?) -> DetectorConfig {
        let expanded = path.expandingTilde
        return DetectorConfig(
            id: makeID(prefix: "repo"),
            name: name,
            category: .repo,
            description: description,
            source: .user,
            detect: DetectRule(type: .path, paths: [expanded], command: nil, appName: nil),
            versionCommand: "git -C \"\(expanded)\" rev-parse --short HEAD 2>/dev/null",
            checkCommand: "git -C \"\(expanded)\" fetch --quiet origin 2>/dev/null || true; commits=$(git -C \"\(expanded)\" rev-list HEAD..@{u} 2>/dev/null || true); [ -n \"$commits\" ] && echo UPDATE || echo OK",
            installCommand: installCommand,
            updateCommand: "cd \"\(expanded)\" && git pull --ff-only",
            workingDirectory: expanded
        )
    }

    static func discoveredRepo(path: String) -> DetectorConfig {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return DetectorConfig(
            id: "discovered-\(path.hashValue)",
            name: name,
            category: .repo,
            description: path,
            source: .discovered,
            detect: DetectRule(type: .path, paths: [path], command: nil, appName: nil),
            versionCommand: "git -C \"\(path)\" rev-parse --short HEAD 2>/dev/null",
            checkCommand: "git -C \"\(path)\" fetch --quiet origin 2>/dev/null || true; commits=$(git -C \"\(path)\" rev-list HEAD..@{u} 2>/dev/null || true); [ -n \"$commits\" ] && echo UPDATE || echo OK",
            installCommand: nil,
            updateCommand: "git -C \"\(path)\" pull --ff-only",
            workingDirectory: path
        )
    }

    static func discoveredSkill(path: String, name: String, kind: String) -> DetectorConfig {
        DetectorConfig(
            id: "discovered-skill-\(path.hashValue)",
            name: name,
            category: .library,
            description: "\(kind) · \(path)",
            source: .discovered,
            detect: DetectRule(type: .path, paths: [path], command: nil, appName: nil),
            versionCommand: "git -C \"\(path)\" rev-parse --short HEAD 2>/dev/null",
            checkCommand: "git -C \"\(path)\" fetch --quiet origin 2>/dev/null || true; commits=$(git -C \"\(path)\" rev-list HEAD..@{u} 2>/dev/null || true); [ -n \"$commits\" ] && echo UPDATE || echo OK",
            installCommand: nil,
            updateCommand: "git -C \"\(path)\" pull --ff-only",
            workingDirectory: path
        )
    }

    static func discoveredApp(info: InstalledAppInfo) -> DetectorConfig {
        let escapedPath = info.path.replacingOccurrences(of: "\"", with: "\\\"")
        let versionCommand: String
        if info.sparkleFeed != nil {
            versionCommand = "short=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \"\(escapedPath)/Contents/Info.plist\" 2>/dev/null); build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \"\(escapedPath)/Contents/Info.plist\" 2>/dev/null); [ -n \"$short\" ] && { [ -n \"$build\" ] && [ \"$build\" != \"$short\" ] && echo \"$short ($build)\" || echo \"$short\"; }"
        } else {
            versionCommand = "/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \"\(escapedPath)/Contents/Info.plist\" 2>/dev/null"
        }
        let checkCommand = "{CHECK_SCRIPT} auto \"\(escapedPath)\""
        // Discovery can identify available releases but cannot safely infer an updater.
        // Keep these items informational instead of launching the app to update it.
        let updateCommand = ""

        var descriptionParts: [String] = [info.path]
        if let sparkleFeed = info.sparkleFeed {
            descriptionParts.append("Sparkle")
            descriptionParts.append(sparkleFeed)
        } else {
            descriptionParts.append(info.bundleID)
        }

        return DetectorConfig(
            id: "discovered-app-\(info.path.hashValue)",
            name: info.name,
            category: .app,
            description: descriptionParts.joined(separator: " · "),
            source: .discovered,
            detect: DetectRule(type: .app, paths: [info.path], command: nil, appName: nil),
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: nil,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }

    static func generic(name: String, category: ItemCategory, detectScript: String, versionCommand: String?, checkCommand: String?, installCommand: String? = nil, updateCommand: String, description: String?) -> DetectorConfig {
        DetectorConfig(
            id: makeID(),
            name: name,
            category: category,
            description: description,
            source: .user,
            detect: DetectRule(type: .command, paths: nil, command: detectScript, appName: nil),
            versionCommand: versionCommand,
            checkCommand: checkCommand,
            installCommand: installCommand,
            updateCommand: updateCommand,
            workingDirectory: nil
        )
    }
}

struct RepoScanOptions {
    let maxDepth: Int
    let skipDirectories: Set<String>
    let skipHidden: Bool
    let limitRootToSubfolders: Bool
    let subfolders: [String]
}

enum RepoScanner {
    private static let sdkDirectoryNames: Set<String> = [
        "flutter", "dart-sdk", "android-sdk", "android", "homebrew", "cellar",
        "rustup-toolchains", "sdk", "sdks", "platform-tools", "cmdline-tools",
        "flutter_sdk", "cocoapods", "gradle", "maven", "gopath", "android-studio",
        "Library", "Android", "Xcode.app", "Xcode"
    ]

    static func discoverRepos(in folders: [String], rootFolder: String, options: RepoScanOptions) -> [DetectorConfig] {
        var results: [DetectorConfig] = []
        var seenPaths: Set<String> = []
        let expandedRoot = rootFolder.expandingTilde

        for folder in folders {
            let expanded = folder.expandingTilde
            guard FileManager.default.fileExists(atPath: expanded) else { continue }

            if options.limitRootToSubfolders && expanded == expandedRoot {
                for subfolder in options.subfolders {
                    let subpath = (expanded as NSString).appendingPathComponent(subfolder)
                    guard FileManager.default.fileExists(atPath: subpath) else { continue }
                    scanDirectory(subpath, depth: 0, maxDepth: options.maxDepth, options: options, results: &results, seen: &seenPaths)
                }
            } else {
                scanDirectory(expanded, depth: 0, maxDepth: options.maxDepth, options: options, results: &results, seen: &seenPaths)
            }
        }

        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func scanDirectory(
        _ path: String,
        depth: Int,
        maxDepth: Int,
        options: RepoScanOptions,
        results: inout [DetectorConfig],
        seen: inout Set<String>
    ) {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitPath) {
            if !isSDKInstallation(path), !seen.contains(path) {
                seen.insert(path)
                results.append(ItemBuilder.discoveredRepo(path: path))
            }
            return
        }

        guard depth < maxDepth else { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for item in contents {
            if shouldSkip(item, options: options) { continue }
            let subpath = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: subpath, isDirectory: &isDir), isDir.boolValue else { continue }
            scanDirectory(subpath, depth: depth + 1, maxDepth: maxDepth, options: options, results: &results, seen: &seen)
        }
    }

    private static func shouldSkip(_ name: String, options: RepoScanOptions) -> Bool {
        if options.skipDirectories.contains(name) { return true }
        if sdkDirectoryNames.contains(name) || sdkDirectoryNames.contains(name.lowercased()) { return true }
        if options.skipHidden && name.hasPrefix(".") { return true }
        return false
    }

    /// Skip SDK/framework git checkouts (Flutter SDK, Android SDK, etc.) — not user project repos.
    static func isSDKInstallation(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let lowered = name.lowercased()
        if sdkDirectoryNames.contains(name) || sdkDirectoryNames.contains(lowered) { return true }

        let fm = FileManager.default
        let binFlutter = (path as NSString).appendingPathComponent("bin/flutter")
        let packagesFlutter = (path as NSString).appendingPathComponent("packages/flutter")
        if fm.fileExists(atPath: binFlutter), fm.fileExists(atPath: packagesFlutter) { return true }

        let binDart = (path as NSString).appendingPathComponent("bin/dart")
        let dartAPI = (path as NSString).appendingPathComponent("include/dart_api.h")
        if fm.fileExists(atPath: binDart), fm.fileExists(atPath: dartAPI) { return true }

        let platformTools = (path as NSString).appendingPathComponent("platform-tools")
        let platforms = (path as NSString).appendingPathComponent("platforms")
        if fm.fileExists(atPath: platformTools), fm.fileExists(atPath: platforms) { return true }

        if path.contains("/homebrew/") || path.hasSuffix("/Cellar") { return true }

        return false
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
