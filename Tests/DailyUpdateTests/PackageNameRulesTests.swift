import XCTest
@testable import DailyUpdate

/// ADR-002 D15: names like `-rf`, `../x`, or a folder name that differs from the manifest name
/// must never reach a command. These tests are the name-rule half of that fixture; `RowBuilder`
/// and the enumerators supply the "folder name differs from manifest name" half.
final class PackageNameRulesTests: HermeticTestCase {
    func testRejectsNamesStartingWithDash() {
        XCTAssertFalse(PackageNameRules.isValidBrewFormulaName("-rf"))
        XCTAssertFalse(PackageNameRules.isValidNpmName("-rf"))
        XCTAssertFalse(PackageNameRules.isValidCaskToken("--eval=x"))
        XCTAssertFalse(PackageNameRules.isValidPyPIName("-x"))
        XCTAssertFalse(PackageNameRules.isValidCrateName("-x"))
        XCTAssertFalse(PackageNameRules.isValidGemName("-x"))
    }

    func testRejectsPathTraversal() {
        XCTAssertFalse(PackageNameRules.isValidBrewFormulaName("../x"))
        XCTAssertFalse(PackageNameRules.isValidNpmName("../x"))
        XCTAssertFalse(PackageNameRules.isValidGemName("a/../../etc/passwd"))
    }

    func testAcceptsOrdinaryNames() {
        XCTAssertTrue(PackageNameRules.isValidBrewFormulaName("gh"))
        XCTAssertTrue(PackageNameRules.isValidBrewFormulaName("node@22"))
        XCTAssertTrue(PackageNameRules.isValidNpmName("typescript"))
        XCTAssertTrue(PackageNameRules.isValidNpmName("@angular/cli"))
        XCTAssertTrue(PackageNameRules.isValidCaskToken("antigravity-ide"))
        XCTAssertTrue(PackageNameRules.isValidPyPIName("browser-use"))
        XCTAssertTrue(PackageNameRules.isValidCrateName("ripgrep"))
        XCTAssertTrue(PackageNameRules.isValidGemName("rails"))
    }

    func testCrateNameLengthCap() {
        XCTAssertTrue(PackageNameRules.isValidCrateName(String(repeating: "a", count: 64)))
        XCTAssertFalse(PackageNameRules.isValidCrateName(String(repeating: "a", count: 65)))
    }

    /// F7: formulae and casks from a non-default tap use `owner/tap/name` in `brew upgrade`.
    func testTapQualifiedName() {
        XCTAssertTrue(PackageNameRules.isValidTapQualifiedName("steipete/tap/bird"))
        XCTAssertFalse(PackageNameRules.isValidTapQualifiedName("bird"))
        XCTAssertFalse(PackageNameRules.isValidTapQualifiedName("-owner/tap/name"))
    }

    func testPEP503Normalization() {
        XCTAssertEqual(PackageNameRules.pep503Normalized("Browser_Use"), "browser-use")
        XCTAssertEqual(PackageNameRules.pep503Normalized("browser.use"), "browser-use")
        XCTAssertEqual(PackageNameRules.pep503Normalized("browser--use"), "browser-use")
    }

    /// §7.4: sanitized before it reaches the UI, the log or `--json`.
    func testSanitizerReplacesControlCharactersAndTruncates() {
        XCTAssertEqual(PackageNameRules.sanitize("hello\u{1B}[31mworld"), "hello?[31mworld")
        XCTAssertEqual(PackageNameRules.sanitize("plain text"), "plain text")
        let long = String(repeating: "a", count: 10)
        XCTAssertEqual(PackageNameRules.sanitize(long, maxLength: 5), "aaaaa…")
    }
}
