import XCTest
@testable import DailyUpdate

final class VersionTests: HermeticTestCase {
    func testVersionMatrixRowsV1ToV4() {
        assertOrder(current: "2.101.0", latest: "2.101.0", expected: .same)
        assertOrder(current: "3.12.0", latest: "3.12.0", expected: .same)
        assertOrder(current: "2.1.0-beta.3", latest: "2.1.0", expected: .older)
        assertOrder(current: "2.1.0", latest: "2.1.0-beta.3", expected: .newer)
    }

    func testVersionMatrixRowV5SemVerChain() {
        let chain = [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0",
        ]

        for pair in zip(chain, chain.dropFirst()) {
            assertOrder(current: pair.0, latest: pair.1, expected: .older)
        }
    }

    func testVersionMatrixRowsV6ToV10() {
        assertOrder(current: "1.2", latest: "1.2.0", expected: .same)
        assertOrder(current: "1.10.0", latest: "1.9.0", expected: .newer)
        assertOrder(current: "1.0.0+20130313", latest: "1.0.0", expected: .same)

        assertOrder(current: "1.2.0b3", latest: "1.2.0rc1", expected: .older)
        assertOrder(current: "1.2.0rc1", latest: "1.2.0", expected: .older)
        assertOrder(current: "3.13.0rc2", latest: "3.13.0", expected: .older)

        assertOrder(current: "3.14.7", latest: "3.14.7_1", expected: .older)
        assertOrder(current: "4.3.5", latest: "4.3.5-52-g1234abc", expected: .older)
        assertOrder(current: "1.0.post1", latest: "1.0", expected: .newer)

        assertOrder(current: "2026.1.23", latest: "2026.9.5", expected: .older)
        assertOrder(current: "20260101", latest: "20260915", expected: .older)
        assertOrder(current: "2026-09-15", latest: "2026.9.15", expected: .same)

        assertOrder(current: "2026.9.5,abc123", latest: "2026.9.5", expected: .same)
        assertOrder(current: "0.2026.09.16.08.27.02", latest: "0.2026.09.16.08.27.03", expected: .older)
    }

    func testVersionMatrixRowsV11AndV12() {
        XCTAssertEqual(
            VersionComparator.compare(.revision("aed9cfd"), .revision("aed9cfd1b2c3")),
            .same
        )
        XCTAssertEqual(
            VersionComparator.compare(.revision("aed9cfd"), .revision("ecefd5b")),
            .incomparable
        )

        XCTAssertEqual(
            VersionComparator.compare(.opaque("latest"), .opaque("LATEST")),
            .same
        )
        XCTAssertEqual(
            VersionComparator.compare(.semantic(Version("1.0.0")!), .opaque("nightly")),
            .incomparable
        )
    }

    func testVersionEqualityUsesNormalizedValueNotRawToken() {
        let compact = Version("1.2")
        let padded = Version("1.2.0")
        XCTAssertEqual(compact, padded)
        XCTAssertEqual(Set([compact, padded]).count, 1)
    }

    private func assertOrder(
        current: String,
        latest: String,
        expected: VersionComparator.Ordering,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(VersionComparator.compare(current: current, latest: latest), expected, file: file, line: line)
    }
}
