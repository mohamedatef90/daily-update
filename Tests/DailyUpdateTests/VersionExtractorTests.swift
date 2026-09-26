import XCTest
@testable import DailyUpdate

final class VersionExtractorTests: HermeticTestCase {
    func testVersionExtractorMatrixRowsE1ToE23() {
        let rows: [(output: String, pattern: String?, token: String?)] = [
            ("gh version 2.101.0 (2026-09-15)", nil, "2.101.0"),
            ("Python 3.12.0", nil, "3.12.0"),
            ("Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)", nil, "6.4"),
            ("Flutter 3.44.6 • channel stable • https://github.com/flutter/flutter.git", nil, "3.44.6"),
            ("pip 23.3.1 from /Library/.../pip (python 3.12)", nil, "23.3.1"),
            ("2.1.281 (Claude Code)", nil, "2.1.281"),
            ("go version go1.22.3 darwin/arm64", nil, "1.22.3"),
            ("mise 2026.9.1 macos-arm64 (2026-09-20)", nil, "2026.9.1"),
            ("The operation couldn't be completed. Unable to locate a Java Runtime.", nil, nil),
            ("21 outdated", nil, nil),
            ("5 skills installed", nil, nil),
            ("rustc 1.80.0 (051478957 2024-07-21)", nil, "1.80.0"),
            ("openjdk version \"21.0.2\" 2024-01-16", nil, "21.0.2"),
            ("v24.13.0", nil, "24.13.0"),
            ("Homebrew 4.3.5-52-g1234abc", nil, "4.3.5-52-g1234abc"),
            ("cargo 1.80.0-nightly (...)", nil, "1.80.0-nightly"),
            ("Python 3.13.0rc2", nil, "3.13.0rc2"),
            ("0.2026.09.16.08.27.02", nil, "0.2026.09.16.08.27.02"),
            ("Composer version 2.8.1 2024-10-04 16:31:01", nil, "2.8.1"),
            ("Dart SDK version: 3.5.0 (stable) ...", nil, "3.5.0"),
            ("version 1.2.3.", nil, "1.2.3"),
            ("Angular CLI: 17.0.0", nil, "17.0.0"),
            ("openjdk version \"21\" 2023-09-19", #"version "([^"]+)""#, "21"),
        ]

        for row in rows {
            XCTAssertEqual(
                VersionExtractor.extract(from: row.output, pattern: row.pattern),
                row.token,
                "output=\(row.output)"
            )
        }
    }

    func testVersionExtractorMatrixRowE24PatternValidation() {
        XCTAssertThrowsError(try VersionExtractor.validate(pattern: #"^\d+\.\d+\.\d+$"#))
        XCTAssertThrowsError(try VersionExtractor.validate(pattern: #"v?(\d+)\.(\d+)"#))
    }
}
