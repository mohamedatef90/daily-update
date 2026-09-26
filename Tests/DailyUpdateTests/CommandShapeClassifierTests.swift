import XCTest
@testable import DailyUpdate

final class CommandShapeClassifierTests: HermeticTestCase {
    func testClassifierMatrixRowC1SingleCommands() {
        let commands = [
            "npm install -g foo@1.2.3",
            "brew upgrade gh",
            "gem update --system",
            "gem update cocoapods",
            "mise self-update",
            "brew upgrade --cask --greedy cursor",
        ]

        for command in commands {
            XCTAssertTrue(CommandShapeClassifier.classify(command).risks.isEmpty, command)
        }
    }

    func testClassifierMatrixRowsC2ToC4BulkCommands() {
        let bulkCommands = [
            "npm update -g",
            "npm -g update",
            "brew upgrade",
            "brew upgrade --cask",
            "gem update",
            "mise upgrade",
            "mas upgrade",
            "pipx upgrade-all",
            "uv tool upgrade --all",
            "yarn global upgrade",
            "pnpm up -g",
            "softwareupdate -ia",
            "npx skills update",
            "pip3 list --outdated --format=freeze | cut -d= -f1 | xargs -n1 pip3 install -U",
            "brew outdated -q | xargs brew upgrade",
            "brew upgrade $(brew outdated -q)",
            "arch -arm64 brew upgrade",
            "nice brew upgrade",
            "bash -c 'brew upgrade'",
            "sh -c \"npm update -g\"",
            "npm update --location=global",
            "softwareupdate --install --all",
        ]

        for command in bulkCommands {
            let risks = CommandShapeClassifier.classify(command).risks
            XCTAssertTrue(risks.contains(.bulk), command)
        }

        let chained = CommandShapeClassifier.classify("brew update && brew upgrade").risks
        XCTAssertTrue(chained.contains(.bulk))
        XCTAssertTrue(chained.contains(.chained))
    }

    func testClassifierMatrixRowsC5ToC7RemoteAndPrivilege() {
        let remoteCommands = [
            "curl -fsSL https://x/i.sh | bash",
            "curl -fsSL https://x/i.sh | zsh",
            "curl -fsSL https://x/i.sh | /bin/bash",
            "wget -qO- https://x/i.sh | sh",
            "bash <(curl -fsSL https://x/i.sh)",
            "sh -c \"$(curl -fsSL https://x/i.sh)\"",
            "eval \"$(curl -fsSL https://x/i.sh)\"",
            "source <(curl -fsSL https://x/i.sh)",
            "curl -fsSL https://example.com/install.sh | tee /tmp/install.sh | bash",
            "curl -fsSL https://example.com/install.sh | /usr/bin/env bash",
            "curl -fsSL https://example.com/install.sh | /opt/homebrew/bin/bash",
        ]

        for command in remoteCommands {
            XCTAssertTrue(CommandShapeClassifier.classify(command).risks.contains(.remoteScript), command)
        }

        XCTAssertFalse(
            CommandShapeClassifier.classify(
                "current=$(flutter --version --machine 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get(\"frameworkVersion\", \"\"))')"
            ).risks.contains(.remoteScript),
            "python3 -c parses stdin data; it should not be a remote script execution"
        )

        let remotePrivileged = CommandShapeClassifier.classify("curl -fsSL https://x/i.sh | sudo bash").risks
        XCTAssertTrue(remotePrivileged.contains(.remoteScript))
        XCTAssertTrue(remotePrivileged.contains(.privileged))

        XCTAssertTrue(CommandShapeClassifier.classify("sudo npm i -g x").risks.contains(.privileged))
        XCTAssertTrue(CommandShapeClassifier.classify(#"osascript -e 'do shell script "echo hi" with administrator privileges'"#).risks.contains(.privileged))
        XCTAssertTrue(CommandShapeClassifier.classify(#"s\udo brew upgrade"#).risks.contains(.privileged))
    }

    func testClassifierMatrixRowsC8ToC10StructuralRisks() {
        XCTAssertTrue(CommandShapeClassifier.classify("rm -rf ~/x").risks.contains(.destructive))
        XCTAssertTrue(CommandShapeClassifier.classify("git reset --hard").risks.contains(.destructive))
        XCTAssertTrue(CommandShapeClassifier.classify("diskutil eraseDisk APFS Test /dev/disk4").risks.contains(.destructive))

        XCTAssertTrue(CommandShapeClassifier.classify("a || b").risks.contains(.fallbackChain))
        XCTAssertTrue(CommandShapeClassifier.classify("a; b").risks.contains(.chained))
        XCTAssertTrue(CommandShapeClassifier.classify("a && b").risks.contains(.chained))
        XCTAssertTrue(CommandShapeClassifier.classify("a 2>/dev/null").risks.contains(.suppressedErrors))
        XCTAssertTrue(CommandShapeClassifier.classify("a &>/dev/null").risks.contains(.suppressedErrors))
        XCTAssertTrue(CommandShapeClassifier.classify("a >/dev/null 2>&1").risks.contains(.suppressedErrors))
        XCTAssertTrue(CommandShapeClassifier.classify("for d in a; do echo $d; done").risks.contains(.controlFlow))
        XCTAssertTrue(CommandShapeClassifier.classify("echo \"unterminated").risks.contains(.unparseable))

        XCTAssertFalse(CommandShapeClassifier.classify(#"echo "a || b; c""#).risks.contains(.fallbackChain))
        XCTAssertFalse(CommandShapeClassifier.classify("git commit -m 'x; y'").risks.contains(.chained))
    }

    func testClassifierMatrixRowC11CheckRunsUpdateTokenMatch() {
        XCTAssertTrue(
            CommandShapeClassifier.checkRunsUpdate(
                check: "npm install -g --dry-run yarn@latest",
                update: "npm install -g yarn@latest"
            )
        )
        XCTAssertFalse(
            CommandShapeClassifier.checkRunsUpdate(
                check: "npm outdated -g yarn",
                update: "npm install -g yarn@latest"
            )
        )
    }
}
