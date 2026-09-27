import XCTest
@testable import DailyUpdate

/// ADR-002 §1's row assembly, against fake records (P2-1's own task list: "using fake records").
/// Fixture numbers below are illustrative — the ADR's D-series fixtures describe real npm/brew
/// trees that land with P2-2/P2-3's enumerators; these prove the same general mechanics (joins,
/// R1-R3, IDs/handles, error rows, custom-item hiding) against synthetic records instead.
final class RowBuilderTests: HermeticTestCase {
    private func root(
        ecosystem: Ecosystem = .fake,
        path: String = "/fixture/root",
        binDirectories: [String] = ["/fixture/root/bin"],
        activity: RootActivity = .active
    ) -> InstallRoot {
        InstallRoot(ecosystem: ecosystem, path: path, label: path, binDirectories: binDirectories, activity: activity)
    }

    private func record(
        ecosystem: Ecosystem = .fake,
        packageID: String,
        displayName: String? = nil,
        root: InstallRoot,
        packageDirectory: String? = nil,
        flags: Set<PackageFlag> = [],
        owner: ResolvedOwner = .unknown,
        inode: UInt64
    ) -> InstalledPackage {
        InstalledPackage(
            ecosystem: ecosystem, packageID: packageID, displayName: displayName, versionRaw: "1.0.0",
            root: root, packageDirectory: packageDirectory ?? "\(root.path)/\(packageID)",
            executables: ["\(root.binDirectories.first ?? root.path)/\(packageID)"], owner: owner, flags: flags,
            confidence: .proven, fileID: FileID(device: 1, inode: inode)
        )
    }

    // MARK: D1-style: join by command keeps the catalog identity

    func testJoinByCommandKeepsCatalogIdentityAndOwner() {
        let ghRoot = root(ecosystem: .brew, path: "/fixture/brew")
        let ghRecord = record(ecosystem: .brew, packageID: "gh", root: ghRoot, owner: .brewFormula("gh"), inode: 10)
        let catalog = [DetectorConfig(
            id: "gh-cli", name: "GitHub CLI", category: .cli, description: nil, command: "gh",
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil
        )]
        let lookup = CommandPathLookup(candidatesByName: ["gh": ["/fixture/brew/bin/gh"]], loginPath: .known(["/fixture/brew/bin"]))
        let fileSystem = StubFileSystem(realpaths: ["/fixture/brew/bin/gh": "/fixture/brew/bin/gh"],
            stats: ["/fixture/brew/bin/gh": FileID(device: 1, inode: 10)])

        let rows = RowBuilder.build(
            input: .init(results: [EnumerationResult(ecosystem: .brew, records: [ghRecord], status: .complete)], lookup: lookup),
            catalog: catalog, fileSystem: fileSystem
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "gh-cli")
        XCTAssertEqual(rows.first?.handle, "brew:gh")
        XCTAssertEqual(rows.first?.source, .inventory)
        XCTAssertEqual(rows.first?.inventory?.packageID, "gh")
    }

    // MARK: D2-style: join by package, later PATH entry is competing (dropped, not duplicated)

    func testJoinByPackageAndLaterPathEntryIsNotItsOwnRow() {
        let activeRoot = root(path: "/fixture/nvm24", binDirectories: ["/fixture/nvm24/bin"])
        let shadowedRoot = root(path: "/fixture/usrlocal", binDirectories: ["/fixture/usrlocal/bin"])
        let active = record(ecosystem: .npm, packageID: "@scope/tool", root: activeRoot, inode: 1)
        let shadowed = record(ecosystem: .npm, packageID: "@scope/tool", root: shadowedRoot, inode: 2)
        let catalog = [DetectorConfig(
            id: "scoped-tool", name: "Scoped Tool", category: .cli, description: nil,
            packages: PackageIdentifiers(npm: "@scope/tool"),
            detect: nil, versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil
        )]
        let lookup = CommandPathLookup(
            candidatesByName: [:],
            loginPath: .known(["/fixture/nvm24/bin", "/fixture/usrlocal/bin"])
        )
        let results = [EnumerationResult(ecosystem: .npm, records: [active, shadowed], status: .complete)]
        let rows = RowBuilder.build(input: .init(results: results, lookup: lookup), catalog: catalog)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "scoped-tool")
        XCTAssertEqual(rows.first?.inventory?.rootPath, "/fixture/nvm24")
    }

    // MARK: D3/D4-style: an inactive root gets no row

    func testInactiveRootRecordGetsNoRow() {
        let inactiveRoot = root(path: "/fixture/nvm20", activity: .inactive)
        let inactive = record(packageID: "clawdbot", root: inactiveRoot, inode: 5)
        let rows = RowBuilder.build(input: .init(results: [
            EnumerationResult(ecosystem: .npm, records: [inactive], status: .complete),
        ]))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: D5-style: a competing record from a different ecosystem doesn't get its own row either

    func testOnlyThePathWinningRecordBecomesARow() {
        let winnerRoot = root(path: "/fixture/native", binDirectories: ["/fixture/native/bin"])
        let loserRoot = root(path: "/fixture/usrlocal", binDirectories: ["/fixture/usrlocal/bin"])
        // Different ecosystems can't share a PackageKey, so this proves the general "one row per
        // winning path position" mechanic using two same-ecosystem records instead (D2/D5's
        // shared mechanic), keeping this test independent of D2's catalog-join test above.
        let winner = record(packageID: "claude", root: winnerRoot, inode: 7)
        let loser = record(packageID: "claude", root: loserRoot, inode: 8)
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/fixture/native/bin", "/fixture/usrlocal/bin"]))
        let rows = RowBuilder.build(input: .init(
            results: [EnumerationResult(ecosystem: .npm, records: [loser, winner], status: .complete)], lookup: lookup
        ))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.inventory?.rootPath, "/fixture/native")
    }

    // MARK: D7-style: a dependency never gets a row

    func testDependencyFlagGetsNoRow() {
        let dependency = record(packageID: "abseil", root: root(), flags: [.dependency], inode: 9)
        let rows = RowBuilder.build(input: .init(results: [
            EnumerationResult(ecosystem: .brew, records: [dependency], status: .complete),
        ]))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: D11-style: one malformed record's issue becomes its own error row; others unaffected

    func testPerRecordIssueBecomesItsOwnErrorRowWithoutAffectingOtherRecords() {
        let good = record(packageID: "typescript", root: root(path: "/fixture/npmroot"), inode: 11)
        let issue = EnumerationIssue(kind: .malformed, rootPath: "/fixture/npmroot/bad-pkg", message: "malformed package.json")
        let results = [EnumerationResult(ecosystem: .npm, records: [good], status: .partial([issue]))]
        let rows = RowBuilder.build(input: .init(results: results))
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.contains { $0.inventory?.packageID == "typescript" })
        let errorRow = rows.first { $0.inventory?.isErrorMarker == true }
        XCTAssertEqual(errorRow?.description, "malformed package.json")
    }

    // MARK: D3/CR#6: two issues on one root collapse to one row, never a duplicate id

    func testTwoIssuesOnOneRootCollapseToOneRowWithBothMessages() {
        let issue1 = EnumerationIssue(kind: .malformed, rootPath: "/fixture/npmroot", message: "malformed package.json")
        let issue2 = EnumerationIssue(kind: .unreadable, rootPath: "/fixture/npmroot", message: "permission denied")
        let results = [EnumerationResult(ecosystem: .npm, status: .partial([issue1, issue2]))]
        let rows = RowBuilder.build(input: .init(results: results))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.description, "malformed package.json; permission denied")
    }

    /// CR#6: filtering this out made a still-blocked ecosystem look like "nothing installed" on
    /// the next run instead of "unknown", which D3 forbids.
    func testPreviousRunStillBlockedGetsAnErrorRowNotSilence() {
        let issue = EnumerationIssue(kind: .previousRunStillBlocked, rootPath: "/fixture/npmroot", message: "still running")
        let results = [EnumerationResult(ecosystem: .npm, status: .partial([issue]))]
        let rows = RowBuilder.build(input: .init(results: results))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.description, "still running")
    }

    // MARK: D12-style: unavailable gives no rows at all

    func testUnavailableStatusGivesNoRows() {
        let rows = RowBuilder.build(input: .init(results: [
            EnumerationResult(ecosystem: .cargo, status: .unavailable("no cargo root")),
        ]))
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: D13-style: a custom item hides the matching inventory row

    func testCustomItemHidesTheMatchingInventoryRow() {
        let fileSystem = StubFileSystem(
            realpaths: ["/fixture/custom/tool": "/fixture/custom/tool"],
            stats: ["/fixture/custom/tool": FileID(device: 1, inode: 42)]
        )
        let matching = record(packageID: "tool", root: root(path: "/fixture/root2"), inode: 42)
        var settings = UserSettings.defaults
        settings.customItems = [DetectorConfig(
            id: "custom-1", name: "My Tool", category: .cli, description: nil,
            detect: DetectRule(type: .path, paths: ["/fixture/custom/tool"], command: nil, appName: nil),
            versionCommand: nil, checkCommand: nil, installCommand: nil, updateCommand: "", workingDirectory: nil
        )]
        let rows = RowBuilder.build(
            input: .init(results: [EnumerationResult(ecosystem: .npm, records: [matching], status: .complete)]),
            settings: settings, fileSystem: fileSystem
        )
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: D19/D20-style: exactly one row for an unknown or empty login PATH, never one per ecosystem

    func testUnknownLoginPathGivesExactlyOneErrorRow() {
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .unknown("exit 1"))
        let results = [
            EnumerationResult(ecosystem: .npm, status: .partial([EnumerationIssue(kind: .loginEnvironmentUnknown, message: "x")])),
            EnumerationResult(ecosystem: .brew, status: .partial([EnumerationIssue(kind: .loginEnvironmentUnknown, message: "y")])),
        ]
        let rows = RowBuilder.build(input: .init(results: results, lookup: lookup))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.description, "Couldn't read your login PATH: exit 1")
    }

    func testEmptyLoginPathMessage() {
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .empty)
        let rows = RowBuilder.build(input: .init(results: [], lookup: lookup))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.description, "Your login shell reported an empty PATH")
    }

    // MARK: D19 variant: unknown PATH — inactive included, no winner collapse, exact row IDs

    /// S4: with an unknown login PATH, an `.inactive` root is treated as `.unknown` (no root is
    /// demoted), there is no ranking signal so no winner collapse happens, and every distinct
    /// file still gets its own row — two copies of one package survive as two rows.
    func testUnknownLoginPathEmitsOneRowPerFileNoWinnerCollapseInactiveIncluded() {
        let rootA = root(path: "/fixture/rootA", binDirectories: ["/fixture/rootA/bin"])
        let rootB = root(path: "/fixture/rootB", binDirectories: ["/fixture/rootB/bin"])
        let inactiveRoot = root(path: "/fixture/rootC", binDirectories: ["/fixture/rootC/bin"], activity: .inactive)
        let copyA = record(ecosystem: .npm, packageID: "widget", root: rootA, inode: 201)
        let copyB = record(ecosystem: .npm, packageID: "widget", root: rootB, inode: 202)
        let inactiveCopy = record(ecosystem: .npm, packageID: "widget", root: inactiveRoot, inode: 203)
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .unknown("exit 1"))
        let results = [EnumerationResult(ecosystem: .npm, records: [copyA, copyB, inactiveCopy], status: .complete)]

        let rows = RowBuilder.build(input: .init(results: results, lookup: lookup))

        let expectedIDs: Set<String> = [
            "inv-error-login-path",
            ItemBuilder.stableID(prefix: "inv-npm", path: "\(rootA.path)\u{0}widget"),
            ItemBuilder.stableID(prefix: "inv-npm", path: "\(rootB.path)\u{0}widget"),
            ItemBuilder.stableID(prefix: "inv-npm", path: "\(inactiveRoot.path)\u{0}widget"),
        ]
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows.map(\.id)), expectedIDs)
        XCTAssertTrue(rows.contains { $0.inventory?.rootPath == inactiveRoot.path })
    }

    // MARK: D20 variant: empty PATH — R1 still merges exact file duplicates, nothing else collapses

    /// S4: with an empty login PATH, two records naming the exact same file (matching `FileID`)
    /// still merge into one row (R1), but two records that merely share a package identity under
    /// different files do not collapse — there's no winner to pick without a PATH.
    func testEmptyLoginPathMergesOnlyExactFileDuplicates() {
        let rootA = root(path: "/fixture/rootD", binDirectories: ["/fixture/rootD/bin"])
        let rootB = root(path: "/fixture/rootE", binDirectories: ["/fixture/rootE/bin"])
        let sameFileFirstSeen = record(ecosystem: .brew, packageID: "gadget", root: rootA, inode: 301)
        let sameFileAgain = record(ecosystem: .brew, packageID: "gadget", root: rootA, inode: 301)
        let distinctFile = record(ecosystem: .brew, packageID: "gadget", root: rootB, inode: 302)
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .empty)
        let results = [EnumerationResult(ecosystem: .brew, records: [sameFileFirstSeen, sameFileAgain, distinctFile], status: .complete)]

        let rows = RowBuilder.build(input: .init(results: results, lookup: lookup))

        let expectedIDs: Set<String> = [
            "inv-error-login-path",
            ItemBuilder.stableID(prefix: "inv-brew", path: "\(rootA.path)\u{0}gadget"),
            ItemBuilder.stableID(prefix: "inv-brew", path: "\(rootB.path)\u{0}gadget"),
        ]
        // 3 rows, not 4: the exact FileID duplicate under rootA merges to one row.
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.id)), expectedIDs)
    }

    // MARK: D18-style: repeated builds over the same input are byte-identical; IDs are stable

    func testRepeatedBuildsAreIdentical() {
        let stableRoot = root(path: "/fixture/root3")
        let stableRecord = record(packageID: "stable-pkg", root: stableRoot, inode: 99)
        let input = RowBuilder.Input(results: [EnumerationResult(ecosystem: .uv, records: [stableRecord], status: .complete)])
        let first = RowBuilder.build(input: input)
        let second = RowBuilder.build(input: input)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.handle), second.map(\.handle))
    }

    // MARK: Handles: `@root` only appended when two rows would otherwise share a handle

    func testHandleGetsRootSuffixOnlyWhenAmbiguous() {
        let uniqueRoot = root(ecosystem: .uv, path: "/fixture/uv-root")
        let unique = record(ecosystem: .uv, packageID: "browser-use", root: uniqueRoot, inode: 50)
        let rows = RowBuilder.build(input: .init(results: [
            EnumerationResult(ecosystem: .uv, records: [unique], status: .complete),
        ]))
        XCTAssertEqual(rows.first?.handle, "uv:browser-use")
    }

    func testMalformedPackageIDNeverBecomesARow() {
        let bad = record(packageID: "-rf", root: root(), inode: 60)
        let rows = RowBuilder.build(input: .init(results: [
            EnumerationResult(ecosystem: .brew, records: [bad], status: .complete),
        ]))
        XCTAssertTrue(rows.isEmpty)
    }
}

/// A minimal `ReadOnlyFileSystem` double for the "join by command" step, which needs only
/// `realpath` and `stat`.
private struct StubFileSystem: ReadOnlyFileSystem {
    let realpaths: [String: String]
    let stats: [String: FileID]

    func contentsOfDirectory(_ path: String) throws -> (entries: [String], truncated: Bool) { ([], false) }
    func readFile(_ path: String, maxBytes: Int) throws -> Data { Data() }
    func lstat(_ path: String) -> FileStat? { nil }
    func stat(_ path: String) -> FileStat? {
        guard let fileID = stats[path] else { return nil }
        return FileStat(mode: mode_t(S_IFREG), uid: 0, device: fileID.device, inode: fileID.inode, size: 0, modificationDate: Date())
    }
    func realpath(_ path: String) -> String? { realpaths[path] ?? path }
    func destinationOfSymlink(_ path: String) -> String? { nil }
}
