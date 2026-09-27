import XCTest
@testable import DailyUpdate

/// ADR-002 §9 P2-1: "the discovery dump is introduced, for the fake ecosystem only." A golden
/// tree of `FakeEnumerator` records run through the exact same `DiscoveryCoordinator` ->
/// `RowBuilder` pipeline `--discover` uses, dumped one line per row so a future change is as easy
/// to diff as `BundledCommandDumpTests`' bundled-command dump. Runs only when
/// `DAILY_UPDATE_DISCOVERY_DUMP` names an output file.
final class DiscoveryDumpTests: HermeticTestCase {
    /// A small, deterministic tree: one plain package, one shadowed-by-PATH-order duplicate, one
    /// dependency (no row), one inactive-root install (no row), and one partial-enumeration issue
    /// (its own Check Failed row).
    private func goldenTreeResult() -> EnumerationResult {
        let activeRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/active", label: "golden active",
            binDirectories: ["/golden/active/bin"], activity: .active
        )
        let shadowedRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/shadowed", label: "golden shadowed",
            binDirectories: ["/golden/shadowed/bin"], activity: .active
        )
        let inactiveRoot = InstallRoot(
            ecosystem: .fake, path: "/golden/inactive", label: "golden inactive",
            binDirectories: ["/golden/inactive/bin"], activity: .inactive
        )

        func package(_ id: String, root: InstallRoot, inode: UInt64, flags: Set<PackageFlag> = []) -> InstalledPackage {
            InstalledPackage(
                ecosystem: .fake, packageID: id, versionRaw: "1.0.0", root: root,
                packageDirectory: "\(root.path)/\(id)", executables: ["\(root.binDirectories[0])/\(id)"],
                owner: .unknown, flags: flags, confidence: .proven, fileID: FileID(device: 1, inode: inode)
            )
        }

        let records = [
            package("widget", root: activeRoot, inode: 1),
            package("widget", root: shadowedRoot, inode: 2),
            package("libwidget", root: activeRoot, inode: 3, flags: [.dependency]),
            package("old-widget", root: inactiveRoot, inode: 4),
        ]
        let issue = EnumerationIssue(kind: .malformed, rootPath: "/golden/active/broken-widget", message: "malformed manifest")
        return EnumerationResult(ecosystem: .fake, roots: [activeRoot, shadowedRoot, inactiveRoot], records: records, status: .partial([issue]))
    }

    func testDumpDiscoveryGoldenTree() throws {
        guard let path = ProcessInfo.processInfo.environment["DAILY_UPDATE_DISCOVERY_DUMP"], !path.isEmpty else {
            throw XCTSkip("Set DAILY_UPDATE_DISCOVERY_DUMP=<file> to write the discovery dump")
        }
        let lookup = CommandPathLookup(
            candidatesByName: [:],
            loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"])
        )
        let rows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))
            .sorted { $0.id < $1.id }

        var lines: [String] = []
        for row in rows {
            lines.append([
                row.id, row.handle ?? "", row.name, row.source?.rawValue ?? "",
                row.inventory.map { "\($0.ecosystem.rawValue):\($0.packageID)@\($0.rootPath)" } ?? "",
                row.description ?? "",
            ].joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Runs the same golden tree end-to-end through `DiscoveryCoordinator` (not just `RowBuilder`
    /// directly), so this also proves the fake ecosystem survives the coordinator's ceiling and
    /// in-flight registry the way a real one will once P2-2/3/4 register their enumerators.
    func testGoldenTreeThroughTheCoordinatorMatchesDirectRowBuilding() async {
        let fake = FakeEnumerator(ecosystem: .fake, behavior: .immediate(goldenTreeResult()))
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"]))
        let context = DiscoveryContext(loginPath: lookup.loginPath)
        let coordinatorResults = await DiscoveryCoordinator.run(
            enumerators: [fake], context: context, registry: DiscoveryInFlightRegistry()
        )
        let coordinatorRows = RowBuilder.build(input: .init(results: coordinatorResults, lookup: lookup))
        let directRows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))
        XCTAssertEqual(coordinatorRows.map(\.id).sorted(), directRows.map(\.id).sorted())
    }

    func testGoldenTreeProducesExpectedRowShape() {
        let lookup = CommandPathLookup(candidatesByName: [:], loginPath: .known(["/golden/active/bin", "/golden/shadowed/bin"]))
        let rows = RowBuilder.build(input: .init(results: [goldenTreeResult()], lookup: lookup))

        // widget: one row, from the active root only (the shadowed copy isn't its own row).
        let widgetRows = rows.filter { $0.inventory?.packageID == "widget" }
        XCTAssertEqual(widgetRows.count, 1)
        XCTAssertEqual(widgetRows.first?.inventory?.rootPath, "/golden/active")

        // libwidget is a dependency: no row.
        XCTAssertFalse(rows.contains { $0.inventory?.packageID == "libwidget" })

        // old-widget is in an inactive root: no row.
        XCTAssertFalse(rows.contains { $0.inventory?.packageID == "old-widget" })

        // The malformed-manifest issue becomes its own Check Failed row.
        XCTAssertTrue(rows.contains { $0.inventory?.isErrorMarker == true && $0.description == "malformed manifest" })

        // Exactly 2 rows total: widget + the one error row.
        XCTAssertEqual(rows.count, 2)
    }
}
