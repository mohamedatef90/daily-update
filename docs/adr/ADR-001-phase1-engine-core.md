## Phase 1 design spec: typed engine core (ADR-001, Phase 1)

**Status:** Ready for Stage 2. **Base:** `fc85e5b`. PR #4 merged it into `master` as `b544c44`, and the trees are identical, so branch from `master`.
**Implementer:** Mobile Engineer (Native). **Reviews:** Code Reviewer on both PRs, and Security Reviewer on PR-B (resolver trust, argv execution, classifier).

This spec is based on the code at `fc85e5b` and on read-only probes run on this Mac (2026-09-24). A ⚠️ marks a tool fact that isn't verified yet. The rule for those: verify it before shipping. If you can't, the item is **Blocked**. Never guess (the G11 lesson).

### 0. Decisions (settled; don't reopen them in Stage 2)

| # | Decision | Why / alternative rejected |
|---|---|---|
| D1 | Typed strategies return an argv `CommandSpec`, and `Process` runs it directly: an absolute executable from the resolved owner, no shell. Only custom and legacy items still go through `zsh -lc`. | Removes quoting/injection bugs and any doubt about which binary ran. Rejected: keeping shell strings for everything. |
| D2 | The resolved path decides the owner. Package IDs in `detectors.json` only validate that decision. | G1: the catalog guessed npm for a native `claude`. |
| D3 | The npm prefix comes from the resolved path (`<prefix>/lib/node_modules/<pkg>`), never from `npm prefix -g`. | Probe: `/usr/local/bin/npm prefix -g` prints the **nvm** prefix, because its `#!/usr/bin/env node` picks up nvm's node. |
| D4 | Commands pin the exact target version wherever the tool allows it (`npm i -g pkg@2.1.281`, `gem install x -v 1.2`, `cargo install x --version 1.2`). | The dry-run then shows exactly what will be installed, and L3 compares like with like. |
| D5 | Only `.updateAvailable` can be selected. Gated and Blocked rows get Copy / Open in Terminal (the Phase 0 path). CLI `--update <id> --yes` may override only the `bulk`, `needsReview` and `pinned` gates, and never overrides Blocked. | Keeps Phase 0's explicit CLI escape hatch without adding a GUI bypass. |
| D6 | Keep `ItemStatus.upToDate` with raw value `"upToDate"`, and label it "Current". Add `gated`, `blocked` and `failedVerification`. | Anything consuming `--check --json` (QA, cron jobs) keeps working. |
| D7 | The aggregate rows (`brew`, `global-npm`, `global-pnpm`, `global-yarn`, `pip-packages`, `gem`, `agent-skills`) stay as allowlisted legacy shell in Phase 1. They are always Gated(`bulk`) and carry no version fields. Phase 2 replaces them with one row per package. | Fixes the count-as-version part of QA defect 7 without pulling Phase 2 forward. |
| D8 | Brew checks read local metadata (`brew info --json=v2` with `HOMEBREW_NO_AUTO_UPDATE=1`) and never run `brew update`. Show the metadata's age when it's older than 24 h (⚠️ confirm the cache path `$(brew --cache)/api/formula.jws.json`). | A check must not write state, and this way the check and `brew upgrade` see the same formula data. |
| D9 | New code goes in `Sources/DailyUpdate/Engine/`: pure logic, no UI or persistence. Update `AGENTS.md` in the same PR. | `Services/` keeps the app wiring. |
| D10 | Two PRs. **PR-A**: version model, outcomes, classifier; no owner changes. **PR-B**: resolver, strategies, catalog v2, L3. Each ships on its own. | Keeps each review a manageable size. PR-A alone fixes G3, QA defect 5 and Security's follow-ups. |

---

### 1. Version model (item 6)

**Types** (`Engine/Version/`):
```swift
struct Version: Hashable, Comparable, CustomStringConvertible {
    enum Identifier: Hashable, Comparable { case numeric(Int), alpha(String) }
    let core: [Int]               // "1.2" -> [1, 2]; missing parts compare as 0
    let prerelease: [Identifier]  // empty = release
    let post: Int?                // "_1" (brew revision), ".post1", "-52-gabc1234" (git describe)
    let raw: String               // the token as extracted, for display
    init?(_ token: String)
}
enum VersionValue: Hashable {
    case semantic(Version)
    case revision(String)         // git SHA. Only strategies that know it's a SHA construct this.
    case opaque(String)           // "latest", "nightly", anything that doesn't parse
    init(token: String)           // generic path: .semantic if it parses, else .opaque
}
enum VersionOrder { case older, same, newer, incomparable }
enum VersionComparator {
    static func compare(_ current: VersionValue, _ latest: VersionValue) -> VersionOrder
    static func isAtLeast(current: String?, latest: String?) -> Bool   // shim, delete in T17
    static func isBehind(current: String?, latest: String?) -> Bool    // shim, delete in T17
}
```

**How a token is parsed** (`Version.init`):
1. Trim whitespace. Drop a leading `v`/`V`. Drop a cask build suffix after the first `,` (`2026.9.5,abc123` becomes `2026.9.5`). Drop SemVer build metadata after `+`.
2. A `YYYY-MM-DD` token becomes core `[Y, M, D]`.
3. The core is `^\d+(\.\d+)*`, with any number of parts. Warp's `0.2026.09.16.08.27.02` has 7.
4. What's left after the core:
   - `_N`, `.postN` and `-N-g<hex>` set `post = N`.
   - Anything else is a prerelease. Split it on `.`. Also split letter and digit runs that have no separator between them: `b3` becomes `[b, 3]` and `rc1` becomes `[rc, 1]`.

**How versions are ordered:**
1. Core parts first, compared as numbers. A missing part counts as 0.
2. Then prerelease. A release sorts above any prerelease. Prerelease identifiers follow SemVer §11.4: numeric is lower than alpha, numbers compare by value, alpha compares by ASCII, and on an equal prefix the shorter list is lower.
3. Then `post`: none < 1 < 2.
4. Build metadata is ignored.

**Fallbacks for versions that aren't SemVer:**
- **Dates:** `2026.9.5` and `20260915` are ordinary numeric cores. `2026-09-15` is handled by rule 2 above.
- **Git SHAs:** two `revision`s are `same` when one is a prefix of the other (at least 7 characters). Otherwise they're `incomparable`.
- **Opaque values:** two `opaque`s are `same` when they're equal ignoring case. Otherwise they're `incomparable`.
- **Mixed kinds:** `incomparable`.
- **Incomparable** always ends as **Check Failed** ("can't compare A with B"), never as an update. The one exception is when the strategy supplies its own order through `LatestRelease.strategyOrder` (git ancestry, or a self-updater's yes/no status).

**Extraction** (`Engine/Version/VersionExtractor.swift`):
```swift
enum VersionExtractor {
    // Takes the first dotted version that isn't glued to a preceding digit or dot. It needs
    // at least 2 parts, so "arm64", "21 outdated" and "5 skills installed" never match.
    static let defaultPattern =
        #"(?<![0-9.])v?(\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]*[0-9A-Za-z]|[a-z]+\d*|_\d+)?)"#
    static func extract(from output: String, pattern: String?) -> String?
    static func validate(pattern: String) throws    // must compile with exactly 1 capture group
}
```
- I ran this pattern against 23 real `--version` strings, including all of QA's defect 5 examples. The first 22 rows of fixture matrix §7.3 E are the expected results.
- A catalog entry can set its own `versionPattern`. It's validated when the catalog loads, and an invalid pattern makes the item Check Failed. Two entries need one today:
  - `homebrew`: `Homebrew (\d+\.\d+\.\d+)`
  - `java`: `version "([^"]+)"`, because Java 17+ can print `"21"` with no dot.
- The raw first line is kept as `currentVersionRaw` for the info panel. `currentVersion` holds only the token (QA defect 5).
- If no token is found, the result is Check Failed. That's the Phase 0 behavior, but stricter: count strings no longer pass.

**Scripts return raw values, and Swift does all the comparison.** `check-app-update.sh` prints `CURRENT: <raw>` and `LATEST: <raw>` lines, or `CHECK_FAILED: <reason>`. Delete `compare_versions` and `normalize_version`, and don't print `UPDATE`/`OK` any more. After PR-B no bundled item uses the script. It stays only for custom items that reference `{CHECK_SCRIPT}`.

---

### 2. Owner resolver (item 7)

**Types** (`Engine/Owner/`):
```swift
enum Owner: Hashable, Codable {
    case brewFormula(name: String)
    case brewCask(token: String)
    case npm(prefix: String, package: String)
    case nativeInstaller(NativeInstallerID)            // .claudeCode
    case pipx(package: String), uvTool(name: String)
    case cargo(crate: String), goInstall(module: String?)
    case gem(name: String, gemExecutable: String)
    case appStore(adamID: Int?)
    case sparkle(feedURL: String)
    case selfUpdatingApp(kind: String)                 // "squirrel", "unknown"
    case selfUpdater(SelfUpdaterID)                    // mise, rustup, bun, composer, flutter, hermes, homebrew
    case versionManager(kind: String)                  // nvm, fnm, mise-shim, asdf, pyenv, rbenv
    case bundledWith(parent: String)                   // dart inside a Flutter SDK
    case gitCheckout(path: String)
    case system(provider: String)                      // "macOS", "Command Line Tools", "Xcode"
    case vendorPackage(pkgID: String?)                 // .pkg installer, python.org framework
    case unknown
}
struct ResolvedInstall: Hashable { let invokedPath: String; let realPath: String; let owner: Owner; let rule: String }
struct OwnerResolution: Hashable {
    let identity: ItemIdentity
    let active: ResolvedInstall                        // the first trusted candidate: what actually runs
    let competing: [ResolvedInstall]                   // every other candidate, deduped by realPath
    var fingerprint: OwnerFingerprint                  // owner + active.realPath + inode + mtime (for L3)
}
protocol PathLookup { func candidates(for names: [String]) async -> [String: [String]] }   // whence -ap
struct EcosystemLayout { /* canonical roots; see below */ static func probe() async -> Self; static func fixture(root: URL) -> Self }
enum OwnerResolver { static func resolve(_ identity: ItemIdentity, layout: EcosystemLayout, lookup: PathLookup) async -> Result<OwnerResolution, ResolveError> }
```

**Resolving a command.** `ZshPathLookup` spawns **one** login shell per check run, not one per item. The names are passed as argv and never interpolated into the script:
`/bin/zsh -lc 'for n in "$@"; do print -r -- "@@$n"; whence -ap -- "$n"; done' zsh claude codex gh …`
- Names must match `^[A-Za-z0-9._+-]+$`, and anything else is rejected.
- The shell sees the same PATH `ShellRunner` uses, so the check and the execution agree. Drop empty and relative PATH entries.
- `whence -ap` repeats entries when PATH has duplicates (seen for `codex` and `node` here), so dedupe the output and keep the order.
- Resolve each candidate with `realpath(3)`. A dangling link or a symlink loop gives a `ResolveError`, which ends as Check Failed.
- Candidate 1 is the **active** install, and the rest are **competing**.

**Layout roots.** These are probed once per run with the owner tool's absolute path, argv only, and a 5 s timeout. If a probe fails or its output isn't trusted, use the default.

| Root | Probe | Default |
|---|---|---|
| Homebrew prefix / Cellar / Caskroom | `brew --prefix`, `--cellar`, `--caskroom` | `/opt/homebrew`, `/usr/local` |
| uv tools | `uv tool dir` | `~/.local/share/uv/tools` |
| pipx venvs | `pipx environment --value PIPX_LOCAL_VENVS` | `~/.local/pipx/venvs`, `~/.local/share/pipx/venvs` |
| cargo | `$CARGO_HOME/bin` | `~/.cargo/bin` (tracking file: `~/.cargo/.crates2.json`) |
| go | `go env GOBIN`, else `$(go env GOPATH)/bin` | `~/go/bin` |
| Claude native | none | `~/.local/share/claude/versions` |
| version-manager shims | none | `~/.local/share/mise/shims`, `~/.asdf/shims`, `~/.pyenv/shims`, `~/.rbenv/shims`, `~/.nvm/versions/node`, fnm node dirs |

**Classification rules.** Match them in order against the canonical `realPath`, and the first match wins. Prefixes are compared **by path component**, so `/opt/homebrew/Cellar2` does not match `…/Cellar`.

| # | Resolved path matches | Owner | Evidence from this Mac |
|---|---|---|---|
| 1 | not trusted (see §6.1) | → **Blocked**(`untrustedPath`) | — |
| 2 | `<Cellar>/<formula>/<ver>/…` | `brewFormula(formula)` | `gh → /opt/homebrew/Cellar/gh/2.101.0/bin/gh`; `uv → …/Cellar/uv/0.12.15/bin/uv` |
| 3 | `<Caskroom>/<token>/<ver>/…` | `brewCask(token)` | a binary installed by a cask |
| 4 | `<P>/lib/node_modules/<pkg>/…` where `<P>/bin/node` exists. Read `pkg` from the path (`@scope/name` for scoped packages) and cross-check the `name` in `package.json`. | `npm(prefix: P, package:)` | `codex → ~/.nvm/versions/node/v24.13.0/lib/node_modules/@openai/codex/bin/codex.js` |
| 5 | `<claude native root>/<ver>` | `nativeInstaller(.claudeCode)` | `~/.local/bin/claude → ~/.local/share/claude/versions/2.1.281` |
| 6 | `<uv tool dir>/<name>/bin/…` | `uvTool(name)` | `browser-use v0.13.10` |
| 7 | `<pipx venvs>/<name>/bin/…` | `pipx(name)` | — |
| 8 | `<cargo bin>/<x>` with the same inode as `<cargo bin>/rustup` | `selfUpdater(.rustup)` | rustup proxies |
| 9 | `<cargo bin>/<x>` listed in `.crates2.json` | `cargo(crate)` | — |
| 10 | `<go bin>/<x>` (module from `go version -m <x>`) | `goInstall(module)` | — |
| 11 | a gem wrapper script (`Gem.activate_bin_path('<gem>', …)`) | `gem(name, gemExecutable)` | `pod` |
| 12 | a shim dir, or `~/.nvm/versions/node/v*/bin/node` itself | `versionManager(kind)` | `node → ~/.nvm/versions/node/v24.13.0/bin/node` |
| 13 | `<X>/bin/dart` or `<X>/bin/cache/dart-sdk/…` where `<X>/bin/flutter` exists | `bundledWith("flutter")` | `dart → ~/Files/…/flutter/bin/dart` |
| 14 | the catalog declares `selfUpdater` and no rule above matched | `selfUpdater(id)` | `flutter` SDK checkout; `mise` from its installer |
| 15 | `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin`, or `xcode-select -p` paths | `system(provider)` | `java`, `git`, `swift` stubs |
| 16 | `pkgutil --file-info <path>` reports a pkg id, or `/Library/Frameworks/Python.framework/…` | `vendorPackage(pkgID)` | `/usr/local/bin/node` (nodejs.org pkg); python.org `python3` |
| 17 | anything else | `unknown` | `~/.local/bin/node → ~/.hermes/node/bin/node` |

**Resolving an app** (identified by bundle ID and/or path). Look it up through `NSWorkspace.urlsForApplications(withBundleIdentifier:)` plus the configured app folders. The first match is active; any other copies are competing. Then classify it, first match wins:
1. `Contents/_MASReceipt/receipt` exists → `appStore(adamID)`, with `adamID` from `mdls -raw -name kMDItemAppStoreAdamID`. Probe: Bitwarden returns `1352778147`, and 24 apps here have a receipt.
2. The app path is an artifact target in the **installed-cask index** → `brewCask(token)`. Build the index once per run from `brew info --json=v2 --cask --installed`, mapping each `artifacts[].app` target to its token. That call takes 0.6 s here.
3. Info.plist has a `SUFeedURL`, or the catalog sets `appcastURL` → `sparkle(feed)`. Dia has a feed; ChatGPT has none in its plist, so the catalog supplies it.
4. `Contents/Frameworks/Squirrel.framework` exists → `selfUpdatingApp("squirrel")`. That's Claude.app and Cursor here.
5. Otherwise → `selfUpdatingApp("unknown")`. Warp is an example.

**Duplicates.** After resolving everything, group rows whose `active.realPath` is the same (for apps, the same bundle path) into one `DuplicateGroup`, with reason "Same install: <path>". This replaces the name and command heuristics in `DuplicateDetector`. When the same package is installed in several places (probe: `gemini` under both nvm and `/usr/local/lib/node_modules`), that doesn't create duplicate rows. The `competing` list is shown on the row instead. Phase 2 owns duplicates across different identities, such as the Antigravity pair.

---

### 3. `UpdateStrategy` protocol (item 8)

```swift
protocol UpdateStrategy: Sendable {
    var id: StrategyID { get }
    /// Default: run the active path with versionArgs (argv) and extract; apps read Info.plist.
    func currentVersion(of target: ResolvedTarget, env: ReadOnlyEnvironment) async throws -> VersionValue
    /// READ-ONLY. Can only use `env`, whose closed query set can't express a mutating command (§6.3).
    func latest(for target: ResolvedTarget, env: ReadOnlyEnvironment) async throws -> LatestRelease
    /// Pure: builds argv. Throws StrategyError.blocked(reason) for anything that's not updatable here.
    func command(for target: ResolvedTarget, to release: LatestRelease) throws -> CommandSpec
    /// Called after the command exits 0. Phase 1: re-resolve, re-read the version, require >= target.
    func verify(_ target: ResolvedTarget, expected: LatestRelease, env: ReadOnlyEnvironment) async -> VerificationResult
}
struct ResolvedTarget { let entry: CatalogEntry; let resolution: OwnerResolution }
struct LatestRelease: Hashable { let value: VersionValue; let source: String; let channel: String?; let strategyOrder: VersionOrder? }
struct CommandSpec: Hashable, Codable {
    enum Kind: String, Codable { case update, install, handoff }   // handoff = open the app / App Store
    let kind: Kind
    let executable: String            // absolute path from the resolution; never a bare name
    let arguments: [String]
    let environment: [String: String] // overlay, e.g. PATH=<prefix>/bin:… for npm
    let workingDirectory: String?
    var displayString: String         // ShellEscaping.quote per argv item; used by dry-run, Copy and Terminal
}
enum StrategyError: Error { case transient(String), unsupported(String), blocked(BlockReason) }
enum VerificationResult { case verified(VersionValue), pendingInApp, failed(evidence: String) }
```
- Strategies are `struct`s with no stored state. The per-run cache (layout, cask index, HTTP responses) lives in `CheckRunContext`, which `ReadOnlyEnvironment` holds.
- `ShellRunner.run(_ spec: CommandSpec)` executes through the existing `runProcess(executablePath:arguments:)`.
- Test: `displayString` round-trips through zsh to the same argv.

**Strategies.** Every `latest()` below is read-only.

| Owner → Strategy | `currentVersion` | `latest()` | `command()` | Blocked / gated when |
|---|---|---|---|---|
| brewFormula → `BrewFormulaStrategy` | `installed[linked].version` from `brew info --json=v2 <name>` | same JSON: `versions.stable`, plus `_<revision>` when revision > 0 | `<brew> upgrade <name>` | Cellar not writable → Blocked(`needsPrivilege`). `pinned: true` → Gated(`pinned`). |
| brewCask → `BrewCaskStrategy` | the **real bundle** `CFBundleShortVersionString` at the artifact target, not brew's record (G8) | `brew info --json=v2 --cask <token>` → `version`, text before the first `,` | `<brew> upgrade --cask [--greedy when auto_updates] <token>` | `version == "latest"` → Check Failed ("cask has no version"). Probe: openclaw's record says 2026.1.23, latest is 2026.9.5, `auto_updates: true`. |
| npm → `NpmStrategy` | the `version` field in `<P>/lib/node_modules/<pkg>/package.json` (a file read, no exec) | `<P>/bin/npm view <pkg>@latest version --json` with `PATH=<P>/bin:…`, so the owning Node's npmrc and registry apply | `<P>/bin/npm install -g --prefix <P> <pkg>@<version>` | `<P>/lib/node_modules` not writable → Blocked(`needsPrivilege`). Declared npm package ≠ path package → Blocked(`ownerMismatch`). |
| pipx → `PipxStrategy` | `pipx list --json` → `venvs.<name>.metadata.main_package.package_version` | PyPI `https://pypi.org/pypi/<pkg>/json`: highest non-yanked version, stable only unless current is a prerelease | `<pipx> upgrade <pkg>` | — |
| uvTool → `UvToolStrategy` | the `<name> v<ver>` line from `uv tool list` | PyPI, as above | `<uv> tool upgrade <name>` | — |
| cargo → `CargoStrategy` | the version in the `.crates2.json` key | crates.io `/api/v1/crates/<crate>` → `crate.max_stable_version` (User-Agent header required) | `<cargo> install <crate> --version <v> --locked` | — |
| gem → `GemStrategy` | the version in the wrapper, or `gem list --local --exact <gem>` | rubygems `/api/v1/versions/<gem>/latest.json` | `<gem> install <gem> -v <v>`, using the owning Ruby's `gem` | system Ruby (`/usr/bin/gem`, `/Library/Ruby`) → Blocked(`systemOwned`) |
| appStore → `MasStrategy` | bundle version | `https://itunes.apple.com/lookup?bundleId=<id>&country=<region>` → `version`, `trackId` (probe: Bitwarden 2026.9.0, ok) | **handoff:** `open macappstore://apps.apple.com/app/id<adamID>` → `updatePending` | ⚠️ Use `mas upgrade <id>` only if it's verified to run without root on the installed mas version. Otherwise keep the handoff. |
| sparkle → `SparkleStrategy` + `AppcastParser` | `CFBundleVersion` for ordering, `CFBundleShortVersionString` for display | GET the feed (HTTPS only), parse with `XMLParser`, pick the best item (rules below) | **handoff:** `open -a <bundle path>` → `updatePending`. Direct install stays off until Phase 3. | An `http:` feed → Check Failed ("insecure feed") |
| selfUpdatingApp → `AppHandoffStrategy` | bundle version | cask metadata as a read-only oracle when the catalog declares `packages.brewCask`, even if brew didn't install the app | **handoff:** `open -a <bundle path>` | no oracle → Blocked(`noReadOnlyLatestSource`), shown as "Updates itself; check inside the app" |
| selfUpdater / nativeInstaller → `SelfUpdaterStrategy` | default (`--version`) | registry entry (below) | registry entry | the entry isn't verified → Blocked(`unverifiedSelfUpdater`) |
| gitCheckout → `GitRepoStrategy` | `.revision(git rev-parse HEAD)` | `git ls-remote <remote> <upstream ref>`, which is read-only and replaces today's `fetch`. `strategyOrder`: tip == HEAD, or tip is a local ancestor of HEAD → `.same`; otherwise `.older`. | `git -C <path> pull --ff-only`, with the existing `RepoSafetyService` stash/preflight | — (also fixes the SHA-as-version nit) |
| versionManager / bundledWith / system / vendorPackage / unknown | — | — | — | Blocked(`managedByVersionManager(kind)` / `bundledWith(parent)` / `systemOwned(provider)` / `vendorInstaller(pkg)` / `unknownOwner`), with a hint like "Updated by nvm" or "Updated by macOS Software Update" |

**Sparkle item selection:**
- Skip items that set `<sparkle:channel>`. Those are beta channels; opting in is a Phase 3 setting.
- Skip items whose `sparkle:os` isn't macOS.
- Skip items where `minimumSystemVersion` is higher than the host, or `maximumSystemVersion` is lower.
- Ignore `<sparkle:deltas>`.
- Order the remaining items by `sparkle:version` (element or enclosure attribute), which is what Sparkle compares against `CFBundleVersion`. Fall back to `shortVersionString` only when the build isn't numeric. Probe: ChatGPT is `26.917.51856` with build `10492`.
- This fixes G5's "the check takes the highest beta, the update installs the first item."

**Self-updater registry** (`Engine/Strategies/SelfUpdaterRegistry.swift`, all in Swift, with no shell anywhere in the JSON). Each entry needs a doc or source citation in a code comment and a fixture captured from real output.

| ID | Read-only status | Update argv | Verified |
|---|---|---|---|
| `claudeCode` (native) | Channel from `~/.claude/settings.json` (⚠️ confirm the key name; default `latest`). Then HTTPS GET `registry.npmjs.org/@anthropic-ai/claude-code`, take `dist-tags[channel]`. Probe: stable 2.1.273, latest 2.1.281, installed 2.1.281 → Current. | `<active> update` | ✅ `claude update --help`: "Check for updates and install if available". It's only ever used as the update, never as the check. |
| `mise` | `mise version --json`: first word of `version` vs `latest`. `latest: null` → Check Failed. | `mise self-update --yes` | ✅ Code Reviewer (source + stub) |
| `rustup` | `rustup check`: parse `update available: a -> b` | `rustup update` | ✅ Code Reviewer (source) |
| `composer` | GitHub releases `composer/composer` latest | `composer self-update` | ✅ Code Reviewer. The writability check applies: it's often root-owned in `/usr/local/bin`. |
| `flutter` | `releases_macos.json` stable hash → version | `flutter upgrade` | ✅ Code Reviewer (ran here) |
| `hermes` | `hermes update --check` | `hermes update --yes` | ✅ help text on this Mac: "Check whether an update is available without installing anything". ⚠️ Capture an output fixture. |
| `homebrew` | GitHub releases `Homebrew/brew` latest, vs `brew --version` (pattern above) | `brew update` | ✅ It updates Homebrew itself; it isn't bulk. |
| `bun` | GitHub releases `oven-sh/bun` latest (`bun-vX.Y.Z` tag) | `bun upgrade` | ⚠️ Confirm the tag format. |
| `openclaw` | `openclaw update status --json` | `openclaw update --yes` | ❌ Not installed here, so it stays **Blocked** until someone verifies it. |

**`detectors.json` shrinks to identity only (schema v2).** The whole bundled file has no shell at all. Before and after:
```jsonc
// v1 (today): four shell strings that guess the owner
{ "id": "claude-code", "detect": {"type":"command","command":"command -v claude …"},
  "versionCommand": "claude --version 2>/dev/null",
  "checkCommand": "npm outdated -g @anthropic-ai/claude-code … && echo UPDATE || echo OK",
  "updateCommand": "npm install -g @anthropic-ai/claude-code@latest" }
// v2: identity only
{ "schemaVersion": 2, "items": [
  { "id": "claude-code", "name": "Claude Code", "category": "cli", "command": "claude",
    "packages": { "npm": "@anthropic-ai/claude-code", "brewCask": "claude-code" },
    "selfUpdater": "claudeCode",
    "install": { "remoteScript": "https://claude.ai/install.sh" } },
  { "id": "java", "name": "Java", "category": "runtime", "command": "java",
    "versionPattern": "version \"([^\"]+)\"", "packages": { "brew": "openjdk" } },
  { "id": "cursor", "name": "Cursor", "category": "app",
    "bundleID": "com.todesktop.230313mzl4w4u92", "appNames": ["Cursor"], "packages": { "brewCask": "cursor" } },
  { "id": "chatgpt", "name": "ChatGPT", "category": "app", "bundleID": "…", "appNames": ["ChatGPT"],
    "appcastURL": "https://persistent.oaistatic.com/codex-app-prod/appcast.xml", "packages": { "brewCask": "chatgpt" } },
  { "id": "impeccable", "name": "Impeccable", "category": "library", "gitPaths": ["{ROOT}/impeccable", "{ROOT}/Projects/impeccable"] },
  { "id": "global-npm", "name": "Global npm packages", "category": "library",
    "legacyShell": { "versionCommand": "…", "checkCommand": "…", "updateCommand": "npm update -g" } }
]}
```
- **Allowed keys:**
  - identity: `id`, `name`, `category`, `description`, and exactly one of `command`, `bundleID` (+ `appNames`) or `gitPaths`
  - version parsing: `versionArgs` (default `["--version"]`), `versionPattern`
  - update sources: `packages` (`brew`, `brewCask`, `npm`, `pipx`, `uv`, `cargo`, `gem`, `masAdamID`), `selfUpdater` (a registry key), `appcastURL` (https only)
  - install: `install`, typed as `{npm|brew|brewCask|remoteScript: …}`
  - `legacyShell`, but **only** for the D7 aggregate allowlist
- **Load-time validation (G17, part of item 15):**
  - Reject unknown keys, unknown `selfUpdater` keys, a bad `versionPattern`, a non-https `appcastURL`, and `legacyShell` outside the allowlist.
  - Reject `{UPDATE_SCRIPT}`/`{CHECK_SCRIPT}` placeholders that don't resolve, instead of leaving them in literally.
  - A lint test enforces all of this on the bundled file.
- **Custom, legacy and imported items keep `DetectorConfig` (v1).** Its shape is persisted in `settings.json`, so it must still decode. They run through `CustomCommandStrategy`:
  - The current version comes from `versionCommand` through the extractor.
  - The check contract is `LATEST:` / `CURRENT:` / `CHECK_FAILED:` / `MANUAL:`. Legacy `UPDATE`/`OK` output still works: it maps to `strategyOrder` with `.opaque("not reported")`.
  - The update runs the string through `zsh -lc`, and the classifier result applies.
- **Discovered apps** (`ItemBuilder.discoveredApp`) produce identity (bundle path and ID) instead of `{CHECK_SCRIPT} auto …`. That means MAS, cask and Sparkle detection also works for the 24 App Store apps (G9).

---

### 4. Outcome states (item 9)

Check pipeline (`Engine/CheckEngine.swift`). The first step that decides the outcome wins:
1. Resolve. No candidates → `notInstalled`. `ResolveError` → **Check Failed**. Untrusted path → **Blocked**.
2. `currentVersion`. No token → **Check Failed**.
3. Strategy for the owner. None → **Blocked**(reason from the owner).
4. `latest()`. `.transient` or a timeout → **Check Failed**. `.unsupported` → **Blocked**(`noReadOnlyLatestSource`).
5. Compare, using `strategyOrder` when it's set. `incomparable` → **Check Failed**. Current is the same or newer → **Current**.
6. `command()`. `.blocked(r)` → **Blocked**(r).
7. `GatePolicy`: the classifier result on the command, plus pins. Any gate → **Gated**(reasons).
8. Otherwise → **Update Available**, which carries the `plannedCommand`.

| Outcome | `ItemStatus` | Selectable | Example on this Mac | Suggested label | `--check` exit |
|---|---|---|---|---|---|
| Current | `upToDate` | no | gh 2.101.0 = 2.101.0 | Current | 0 |
| Update Available | `updateAvailable` | **yes (the only one)** | openclaw cask: bundle behind 2026.9.5 | Update available | 0 |
| Gated | `gated` + `gateReasons: [GateReason]` | no. CLI `--update <id> --yes` overrides only `bulk`, `needsReview` and `pinned`. | `global-npm` (bulk), a custom `a; b` (needsReview), a pinned item | Needs you | 0 |
| Blocked | `blocked` + `blockReason` | no | `/usr/bin/java`, nvm `node`, python.org `python3`, a root-owned npm prefix | Can't update here | 0 |
| Check Failed | `checkFailed` | no | offline feed, stub output, SHAs that can't be compared | Check failed | 1 |
| Failed Verification | `failedVerification` | no. Retry re-checks first. | npm exits 0 but the version didn't change (the old claude-code case) | Didn't update | 1 (action) |

```swift
enum GateReason: String, Codable, CaseIterable { case bulk, remoteScript, privileged, destructive, needsReview, pinned }
enum BlockReason: Codable, Hashable {
    case unknownOwner, noStrategy(String), systemOwned(String), vendorInstaller(String?), managedByVersionManager(String)
    case bundledWith(String), needsPrivilege(path: String), untrustedPath(path: String)
    case ownerMismatch(expected: String, found: String), noReadOnlyLatestSource
    case unverifiedSelfUpdater(String), unsafeCheckCommand, manualOnly(String)
}
```

**Selection rules.** These replace `canUpdate` and `BulkUpdatePolicy`:
- **Update** is selectable exactly when `status == .updateAvailable` and the item isn't snoozed or ignored.
- **Install** is unchanged from Phase 0: `notInstalled` plus an install spec. `remoteScript` installs are only reachable through `--install <id> --yes`.
- `updatePending`, `error` and `failedVerification` can't be selected. **Retry re-checks that one item.** It is selected and sent to the dry-run only if the re-check returns Update Available. This also closes the stale-retry-command hole.
- Snoozed and ignored items keep the Phase 0 behavior (`unknown` plus a message, never Current).
- Pins: `pinnedVersion` set and target ≠ pin → Gated(`pinned`). Gating major-version jumps stays in Phase 3.
- `UpdateResult.stillBehind` goes away. After an exit-0 command, `verify()` returns `failedVerification` with evidence (before, after, target, command, the stdout/stderr tail).
- CLI JSON adds `owner {kind, package, activePath, competingPaths}`, `gateReasons`, `blockReason`, `latestSource` and `plannedCommand`. `failedVerification` counts as a failure in exit codes.

---

### 5. Command-shape classifier

This replaces the ID list in `BulkUpdatePolicy`, the remote-script regex in `ActionCommandPolicy`, `commandReviewWarning`, and both copies of `hasFallbackChain`. It applies to update, install, check and version commands of **custom, legacy and imported items**, and to the displayed argv of every typed `CommandSpec` as a defense-in-depth assertion.

```swift
enum ShellLexer { static func parse(_ command: String) -> Result<ShellCommandLine, ShellLexError> }
// Handles '…', "…", \-escapes, $(…), `…`, <(…), |, ||, &&, ;, &, newlines, redirections, VAR=x prefixes, and
// control flow (if/for/while/case/{ }/( )/function). If it can't parse something, it reports .unparseable; it never guesses.
enum CommandRisk: String, Codable, CaseIterable {
    case bulk, remoteScript, privileged, destructive          // gates that never go away
    case fallbackChain, chained, suppressedErrors, controlFlow, unparseable   // → needsReview
}
struct CommandClassification: Equatable { let risks: Set<CommandRisk>; let managers: Set<PackageManager>; var isSingle: Bool { risks.isEmpty } }
enum CommandShapeClassifier {
    static func classify(_ command: String) -> CommandClassification
    static func classify(_ spec: CommandSpec) -> CommandClassification
    static func checkRunsUpdate(check: String, update: String) -> Bool   // token-level (Code Reviewer S1)
}
```

**Normalizing each simple command before matching:**
- Strip `env` and `VAR=x` prefixes, and `command`, `exec`, `nohup` and `time`.
- Reduce absolute paths to their basename (`/bin/bash` → `bash`).
- Record `sudo`, `doas`, `su` or `pkexec` as privileged, then keep matching the rest of the argv.

**Risk rules:**

| Risk | Matches |
|---|---|
| `remoteScript` | (a) a pipeline where a fetcher (`curl`, `wget`, `fetch`, `http`) comes before an interpreter (`sh`, `bash`, `zsh`, `dash`, `ksh`, `fish`, `python*`, `perl`, `ruby`, `node`), including through `sudo`; (b) an interpreter given a `<(…)` or `$(…)` that contains a fetcher, which covers `bash <(curl …)` and `sh -c "$(curl …)"`; (c) `eval "$(curl …)"`; (d) `source <(curl …)` or `. <(curl …)`. This covers the forms Security listed: `\| zsh`, `\| sudo bash`, `\| /bin/bash`, `bash <(curl …)`, `sh -c "$(curl …)"`. |
| `bulk` | Only when no operands follow the subcommand: `brew upgrade [--cask] [--greedy]`, `npm update\|up\|upgrade -g`, `npm -g update`, `pnpm update\|up -g`, `yarn global upgrade`, `gem update` (but `gem update --system` and `gem update <gem>` are single), `mise upgrade\|up`, `mas upgrade`, `pipx upgrade-all`, `uv tool upgrade --all`, `cargo install-update -a`, `softwareupdate -i -a`/`-ia`, `npx skills update`. Also `xargs … <pm> install` and `pip install -U $(…)`. Unlike the Phase 0 patterns, these match any segment of a compound, so `brew update && brew upgrade` is caught. |
| `privileged` | `sudo`, `doas`, `su`, `pkexec`; `osascript` with an argument containing `with administrator privileges` |
| `destructive` | `rm` with `-r`/`-R`/`-f`, `dd`, `mkfs*`, `diskutil erase*\|partitionDisk`, `chmod -R`, `chown -R`, `git clean -f*`, `git reset --hard`, `shred`, `srm` |
| `fallbackChain` / `chained` / `suppressedErrors` / `controlFlow` / `unparseable` | a `\|\|` joiner / `;`, `&&` or a newline between commands / `2>/dev/null`, `&>/dev/null`, `>/dev/null 2>&1`, `2>&-` / if, for, while, case, `{…}`, `(…)` / lexer error |

Operators inside quotes don't count, so `echo "a || b"` is a single command.

**From risks to gates** (`GatePolicy`):
- `bulk`, `remoteScript`, `privileged` and `destructive` → the matching gate. It is always kept, with a manual Copy / Open in Terminal path.
- Any risk in the needs-review group → Gated(`needsReview`), **unless** the user has reviewed this exact command. That's stored as `ItemPreference.reviewedCommandHash = SHA-256(command)`. Changing the command invalidates it.
  - **Import strips every `reviewedCommandHash`** (`ConfigImportExport.importData`), so an imported command always arrives un-reviewed.
  - The "Needs review" badge (S3) is a separate `ItemListView` badge, not a line appended to the description. It has a "Mark reviewed" action that shows the full command.
- For a custom **check or version** command:
  - If it has `remoteScript`, `privileged`, `destructive` or `bulk` → it doesn't run, and the item is Blocked(`unsafeCheckCommand`).
  - If `checkRunsUpdate(check, update)` → also Blocked. The check is a token-subsequence match per pipeline segment, so `npm install -g --dry-run yarn@latest` against `npm install -g yarn@latest` is caught.
- For typed bundled commands: tests assert `classify(spec).isSingle` across the whole fixture matrix, and at runtime a non-single spec becomes Blocked (defense in depth).

---

### 6. Security

**6.1 How resolved paths are trusted** (`Engine/Owner/PathTrust.swift`):
- **Canonical paths.** Every decision uses the `realpath(3)` result. Relative and empty PATH entries are dropped.
- **Ownership and permissions.** The executable and **every ancestor directory** must be owned by uid 0 or the current user, and must not be world-writable. That includes sticky dirs like `/tmp`, so a binary under `/tmp` is Blocked(`untrustedPath`). Group-writable `admin` directories such as `/usr/local/bin` are accepted.
- **Layout roots.** Roots returned by probes must pass the same check, or they're ignored. The items under them then fall through to `unknown`, which is Blocked.
- **Package names.** A package name read from a file (`package.json`, `.crates2.json`, a gem wrapper) must match a strict per-ecosystem regex (npm: `^(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*$`) and may not start with `-`. If the catalog declares a package for that owner and it's different → Blocked(`ownerMismatch`).
- **Execution.** Commands always run the absolute path of the owner's tool (`<P>/bin/npm`, `<prefix>/bin/brew`, the active path for self-updaters). A bare name is never looked up through PATH at run time.
- **Known residual risk.** `ShellRunner.defaultPath` adds every `~/*/bin`, so a repo checked out at `~/foo` with a `bin/node` can shadow the real tool. The resolver reports it as `unknown`, which is Blocked, so it fails safe. Phase 3 aligns PATH with the user's interactive shell (G12).

**6.2 No privileged execution:**
- Nothing in the engine builds `sudo`, `osascript … with administrator privileges` or `do shell script`.
- If an update needs to write somewhere the user can't (the npm prefix, the Cellar, a system gem dir, a root-owned composer), the item is Blocked(`needsPrivilege`) and offers the manual Terminal path.
- A lint test scans `Sources/` and the bundled JSON for those strings, and checks every fixture `CommandSpec`.

**6.3 A check never runs the update command:**
- **Structural.** `latest()` and `currentVersion()` only receive a `ReadOnlyEnvironment`. It exposes:
  - `run(_ q: ReadOnlyQuery)`. `ReadOnlyQuery` values come only from static factories in `ReadOnlyQueries.swift` (`.brewInfoFormula`, `.npmView`, `.gitLsRemote`, …), and its `init` is `fileprivate`.
  - `fetch(_ url:)`: HTTPS only, allowlisted hosts (`registry.npmjs.org`, `pypi.org`, `crates.io`, `rubygems.org`, `formulae.brew.sh`, `itunes.apple.com`, `api.github.com`, `storage.googleapis.com`, plus the feed host from the app's own `SUFeedURL` or the catalog `appcastURL`), a 5 MB response cap and a 10 s timeout.
  - There is no way to hand a `CommandSpec` to it.
- **Tests:**
  - Every factory's argv must avoid mutating verbs (`install`, `upgrade`, `update`, `self-update`, `uninstall`, `pull`, `fetch`, `--yes`, `-y`).
  - For every strategy fixture, the `latest()` argv must not token-contain the `command()` argv.
  - The fake environment records every call, and a check must not record a single `CommandSpec`.
- **Environment during checks:** `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_ANALYTICS=1`, `NPM_CONFIG_UPDATE_NOTIFIER=false`, `NO_UPDATE_NOTIFIER=1`. Default check timeouts are 20 s per process and 10 s per HTTP call; Phase 4 tunes them.

**6.4 L3: re-verify each command right before it runs, and don't check during an update:**
- When the dry-run opens, it builds an `ExecutionPlan` of `PlannedAction { itemID, kind, strategyID, ownerFingerprint, command: CommandSpec, target: VersionValue? }`. `DryRunEntry` shows `command.displayString`, and `confirmDryRun()` passes the **plan** to `updateSelected(plan:)`, not IDs.
- **Right before each action**, the run re-plans that one item. It re-resolves the owner and recomputes `command()` against the **planned** target, with no network access. If the fingerprint, owner or `CommandSpec` differs, the action is skipped and logged "changed since you confirmed, not run". For custom items, the fingerprint is the command string, its classification and the working directory. Example: updating `node` through brew moves the npm prefix, so a later npm action in the same run is skipped instead of running against the wrong Node.
- `checkAll()` starts with `guard !isUpdating` and logs "Check skipped: an update is running". Because the guard is inside `checkAll()`, it covers every caller: the toolbar (`ContentView.swift:29`), the status bar item (`StatusBarController.swift:78`), the scheduler (`SchedulerService.swift:39`), the wake observer (`AppState.swift:942`), startup and add-item (`AppState.swift:410/422`) and `DailyUpdateApp.swift:34`.
- `reloadConfigs()` while updating is deferred until the run ends (`needsReloadAfterRun`).
- `updateSelected` refuses to start while `isChecking` is set.
- The window between re-verification and exec is milliseconds. It's accepted and documented.

**6.5 Custom and imported items:** see §5. Review hashes are stripped on import, and unsafe check commands never run. The import confirmation UI stays in Phase 4 (item 15), and this is what it builds on.

---

### 7. Files, ordered TDD tasks, fixture matrix

**7.1 Files.**
- **Add** (`Sources/DailyUpdate/Engine/`):
  - `Version/`: `Version.swift`, `VersionValue.swift`, `VersionComparator.swift` (replaces `Services/VersionComparator.swift`), `VersionExtractor.swift`
  - `Owner/`: `Owner.swift`, `OwnerResolution.swift`, `OwnerResolver.swift`, `AppOwnerResolver.swift`, `EcosystemLayout.swift`, `PathLookup.swift`, `PathTrust.swift`, `InstalledCaskIndex.swift`
  - `Strategies/`: `UpdateStrategy.swift`, `StrategyRegistry.swift`, `ReadOnlyEnvironment.swift`, `ReadOnlyQueries.swift`, `CommandSpec.swift`, `BrewFormulaStrategy.swift`, `BrewCaskStrategy.swift`, `NpmStrategy.swift`, `PipxStrategy.swift`, `UvToolStrategy.swift`, `CargoStrategy.swift`, `GemStrategy.swift`, `MasStrategy.swift`, `SparkleStrategy.swift`, `AppcastParser.swift`, `AppHandoffStrategy.swift`, `SelfUpdaterStrategy.swift`, `SelfUpdaterRegistry.swift`, `GitRepoStrategy.swift`, `CustomCommandStrategy.swift`
  - `Commands/`: `ShellLexer.swift`, `CommandShapeClassifier.swift`, `GatePolicy.swift`
  - top level: `CheckEngine.swift`, `CheckRunContext.swift`, `ExecutionPlan.swift`
  - also `Models/CatalogEntry.swift` (schema v2) and `Models/Outcome.swift` (`GateReason`, `BlockReason`)
- **Change:**
  - `Models/ItemCategory.swift`: new statuses; `UpdateItem` gains `resolution`, `gateReasons`, `blockReason`, `plannedCommand` and `currentVersionRaw`; `canUpdate` becomes `.updateAvailable` only; `needsAdministratorPermission` becomes `blockReason == .needsPrivilege`
  - `Models/ExtendedModels.swift`: `ItemPreference.reviewedCommandHash`; `DryRunEntry` gets `PlannedAction`
  - `Models/UpdateResult.swift`: `failedVerification`; drop `stillBehind`
  - `Services/UpdateCheckService.swift`: becomes a thin adapter over `CheckEngine`
  - `Services/DetectionService.swift`: custom items only
  - `Services/UpdateExecutor.swift`: runs a `CommandSpec`, then calls `verify()`; sleeps only for handoffs
  - `Services/AppState.swift`: `checkAll` goes through the engine, plus the L3 guards and plan-based `updateSelected`; Retry re-checks first
  - `Services/ConfigLoader.swift`: loads and validates v2; placeholder validation
  - `Services/FeatureServices.swift`: `DuplicateDetector` by `realPath`; import strips review hashes
  - `Services/ScanService.swift`: `discoveredApp` produces identity
  - `Services/CLIRunner.swift`: new JSON fields and exit codes; gate overrides per D5
  - `Services/ShellRunner.swift`: `run(CommandSpec)`; PATH sanitizing
  - `Resources/detectors.json`: v2
  - `Resources/scripts/check-app-update.sh`: `LATEST:` contract
  - `Views/ItemListView.swift`, `ItemInfoView.swift`, `DashboardView.swift`: badges and reasons; owner and competing paths in the info view; "Mark reviewed"
  - `Package.swift`: test target gets `resources: [.copy("Fixtures")]`
  - `AGENTS.md`: the `Engine/` folder; the test target exists
- **Delete:** `Services/BulkUpdatePolicy.swift`, `Services/UpdateCommandSemantics.swift`. The handoff check moves to `CommandSpec.Kind` for typed items and into `CustomCommandStrategy` for legacy ones. The remote-script, bulk and fallback helpers in `ActionCommandPolicy.swift` move to the classifier. Keep that file only if the lint tests still need its `PackageManager` enum; otherwise move the enum as well.
- **Tests:** split `CoreServiceTests.swift` by subject: `VersionTests`, `VersionExtractorTests`, `CommandShapeClassifierTests`, `GatePolicyTests`, `OwnerResolverTests`, `AppOwnerResolverTests`, `StrategyTests/*`, `AppcastParserTests`, `CheckEngineTests`, `ExecutionPlanTests`, `CatalogSchemaTests`, `SelectionRulesTests`. Keep the existing 45 tests passing throughout.
  - **Fixture helpers:**
    - `FixtureFileSystem` builds temp trees with files, executables, **relative and absolute symlinks**, modes and fake `.app` bundles (Info.plist, `_MASReceipt`, `Squirrel.framework`).
    - `FixturePathLookup` does a Swift PATH search over that tree (the same semantics as `whence -ap`).
    - `FakeReadOnlyEnvironment` returns canned query and URL responses and records every call.
    - `RecordingExecutor` records the `CommandSpec`s it runs.
  - **Captured fixtures** go in `Tests/DailyUpdateTests/Fixtures/`, with `/Users/<name>` replaced by `{HOME}` (per AGENTS.md: no local paths):
    - `brew-info-gh.json`, `brew-info-cask-openclaw.json`, `brew-casks-installed.json`
    - `npm-view-claude-code-dist-tags.json`, `itunes-lookup-bitwarden.json`, `appcast-dia.xml`, `appcast-channels.xml` (synthetic)
    - `mise-version.json`, `rustup-check.txt`, `flutter-releases.json` (trimmed), `pypi-*.json`, `crates-*.json`, `rubygems-*.json`
    - `pipx-list.json`, `uv-tool-list.txt`, `crates2.json`, `hermes-update-check.txt` (⚠️ capture)

**7.2 Ordered TDD tasks.** Each task writes failing tests first, then the code, as one commit, with `swift test` green at the end of every task.

*PR-A: version, outcomes, classifier (≈3 days)*
1. **T0 Phase 0 carry-overs:**
   - wrap `setAppSupportDirectoryForTesting` in `#if DEBUG`
   - make the remaining `loadConfigs` tests hermetic
   - log "Nothing run: all items changed since you confirmed"
   - split the test file by subject
2. **T1 `Version` + `VersionComparator.compare`.** Fixture matrix V. Keep the `isAtLeast`/`isBehind` shims pointing at the new code, so G3 is fixed for existing callers right away.
3. **T2 `VersionExtractor` + `versionPattern` + `currentVersionRaw`.** Fixture matrix E. Wire it into the current `UpdateCheckService`, which fixes QA defect 5.
4. **T3 Outcome model:**
   - add the statuses and reasons, the selection rules, Retry-as-recheck, and the CLI JSON fields and exit codes
   - fixture matrix S
5. **T4 `ShellLexer` + `CommandShapeClassifier` + `checkRunsUpdate`.** Fixture matrix C.
6. **T5 `GatePolicy`:**
   - replace `BulkUpdatePolicy`, the remote-script regex and `commandReviewWarning`
   - add review hashes, strip them on import, add the Needs-review badge and "Mark reviewed", and block unsafe custom checks
   - move the lint tests onto the classifier
   - delete `BulkUpdatePolicy` and `UpdateCommandSemantics`
7. **T6 `CommandSpec` + `ShellRunner.run(spec)` + `displayString`.** Test the zsh round-trip. Copy, Open in Terminal and dry-run use `displayString`.

*PR-B: resolver, strategies, catalog v2, L3 (≈5–6 days)*

8. **T7 `PathTrust`, `PathLookup`** (batched `whence -ap` + fixture lookup), **`EcosystemLayout`** (probe + fixture). Fixture matrix O, rows 14–16.
9. **T8 `OwnerResolver` command rules 1–17, plus competing paths.** Fixture matrix O.
10. **T9 `AppOwnerResolver` + `InstalledCaskIndex`.** Fixture matrix A.
11. **T10 `UpdateStrategy`, `ReadOnlyEnvironment`/`ReadOnlyQueries`, `StrategyRegistry`, `CheckEngine` pipeline.** Use a fake strategy. Fixture matrix F (G2, fail closed) and the read-only structural tests.
12. **T11 Brew formula + cask strategies.**
13. **T12 npm strategy:** prefix from the path, `package.json` current version, owning `npm view`, writability.
14. **T13 Sparkle + `AppcastParser`, MAS (lookup + handoff), app handoff with the cask oracle.**
15. **T14 pipx, uv, cargo, gem strategies.**
16. **T15 self-updater registry** (verified entries only; the others Blocked) + `GitRepoStrategy` (`ls-remote`).
17. **T16 Catalog v2:**
    - `CatalogEntry`, migrate all 49 entries, and load-time validation
    - lint tests: "bundled JSON has no shell outside the D7 allowlist" and "every typed command `isSingle`"
    - `discoveredApp` produces identity
    - `DuplicateDetector` by `realPath`
    - the `LATEST:` script contract
18. **T17 Execution:**
    - `ExecutionPlan` and L3 re-verification before each action
    - the `checkAll`, `reloadConfigs` and `updateSelected` guards
    - minimal `verify()` and Failed Verification
    - delete the comparator shims
    - fixture matrix L
19. **T18 UI and CLI surface:** badges and reasons, the owner and competing paths in `ItemInfoView`, and updates to `AGENTS.md` and `README.md`.

The total is ≈ 8–9 dev days, a little over the ADR's "≈1 week", because it includes the Phase 0 backlog and 13 strategies plus the self-updater registry. If time runs short, T14 (pipx, uv, cargo, gem) can slip to Phase 2 without harm: those owners resolve to Blocked(`noStrategy`) until it lands.

**7.3 Fixture matrix.** Each row becomes at least one test.

*V: ordering (G3)* → `VersionTests`

| # | current | latest | expected |
|---|---|---|---|
| V1 | `gh version 2.101.0 (2026-09-15)` (after extraction) | `2.101.0` | same |
| V2 | `Python 3.12.0` (after extraction) | `3.12.0` | same |
| V3 | `2.1.0-beta.3` | `2.1.0` | **older** |
| V4 | `2.1.0` | `2.1.0-beta.3` | **newer** |
| V5 | SemVer §11 chain `1.0.0-alpha < -alpha.1 < -alpha.beta < -beta < -beta.2 < -beta.11 < -rc.1 < 1.0.0` | — | each adjacent pair is older |
| V6 | `1.2` / `1.10.0` / `1.0.0+20130313` | `1.2.0` / `1.9.0` / `1.0.0` | same / newer / same |
| V7 | `1.2.0b3` / `1.2.0rc1` / `3.13.0rc2` | `1.2.0rc1` / `1.2.0` / `3.13.0` | older / older / older |
| V8 | `3.14.7` / `4.3.5` / `1.0.post1` | `3.14.7_1` / `4.3.5-52-g1234abc` / `1.0` | older / older / newer |
| V9 | `2026.1.23` / `20260101` / `2026-09-15` | `2026.9.5` / `20260915` / `2026.9.15` | older / older / same |
| V10 | `2026.9.5,abc123` (cask) / `0.2026.09.16.08.27.02` | `2026.9.5` / `0.2026.09.16.08.27.03` | same / older |
| V11 | `.revision("aed9cfd")` | `.revision("aed9cfd1b2c3…")` / `.revision("ecefd5b")` | same / **incomparable → Check Failed** |
| V12 | `.opaque("latest")` / `.semantic(1.0)` | `.opaque("LATEST")` / `.opaque("nightly")` | same / incomparable |

*E: extraction* → `VersionExtractorTests`, default pattern unless stated otherwise.

| # | Output | Token |
|---|---|---|
| E1 | `gh version 2.101.0 (2026-09-15)` | `2.101.0` |
| E2 | `Python 3.12.0` | `3.12.0` |
| E3 | `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)` | `6.4` |
| E4 | `Flutter 3.44.6 • channel stable • https://github.com/flutter/flutter.git` | `3.44.6` |
| E5 | `pip 23.3.1 from /Library/…/pip (python 3.12)` | `23.3.1` |
| E6 | `2.1.281 (Claude Code)` | `2.1.281` |
| E7 | `go version go1.22.3 darwin/arm64` | `1.22.3` |
| E8 | `mise 2026.9.1 macos-arm64 (2026-09-20)` | `2026.9.1` |
| E9 | `The operation couldn't be completed. Unable to locate a Java Runtime.` | nil → Check Failed |
| E10 | `21 outdated` | nil |
| E11 | `5 skills installed` | nil |
| E12 | `rustc 1.80.0 (051478957 2024-07-21)` | `1.80.0` |
| E13 | `openjdk version "21.0.2" 2024-01-16` | `21.0.2` |
| E14 | `v24.13.0` | `24.13.0` |
| E15 | `Homebrew 4.3.5-52-g1234abc` | `4.3.5-52-g1234abc` |
| E16 | `cargo 1.80.0-nightly (…)` | `1.80.0-nightly` |
| E17 | `Python 3.13.0rc2` | `3.13.0rc2` |
| E18 | `0.2026.09.16.08.27.02` | the whole string |
| E19 | `Composer version 2.8.1 2024-10-04 16:31:01` | `2.8.1` |
| E20 | `Dart SDK version: 3.5.0 (stable) …` | `3.5.0` |
| E21 | `version 1.2.3.` | `1.2.3` |
| E22 | `Angular CLI: 17.0.0` | `17.0.0` |
| E23 | `openjdk version "21" 2023-09-19` with the java pattern | `21` |
| E24 | a pattern with 0 or 2 capture groups | rejected at load |

*O: command owner resolution through symlinks (G1)* → `OwnerResolverTests`, on a `FixtureFileSystem` with `{HOME}` and `{BREW}` roots.

| # | Tree | Expected |
|---|---|---|
| O1 | `{HOME}/.local/bin/claude → ../share/claude/versions/2.1.281` (relative) | `nativeInstaller(claudeCode)`. The strategy's argv is `[{HOME}/.local/bin/claude, update]`, and **no npm call happens** during the check or the update (the G1 regression). |
| O2 | `{HOME}/.nvm/versions/node/v24.13.0/bin/codex → ../lib/node_modules/@openai/codex/bin/codex.js`, `package.json` name `@openai/codex` | `npm(prefix: …/v24.13.0, "@openai/codex")`. The command is `[<P>/bin/npm, install, -g, --prefix, <P>, @openai/codex@X]` with PATH starting `<P>/bin`. |
| O3 | `{BREW}/bin/gh → ../Cellar/gh/2.101.0/bin/gh` | `brewFormula(gh)` |
| O4 | `gemini`: nvm prefix first, then `/usr/local/bin/gemini → ../lib/node_modules/@google/gemini-cli/dist/index.js` | the nvm prefix is active; `/usr/local` is recorded as competing; still one row |
| O5 | `node`: nvm, `{BREW}/opt/node@22 → ../Cellar/node@22/22.22.2` (**symlinked directory**), a real file at `/usr/local/bin/node` (pkg), `{HOME}/.local/bin/node → {HOME}/.hermes/node/bin/node` | active: `versionManager(nvm)` → Blocked; 3 competing, classified brewFormula(node@22) / vendorPackage / unknown |
| O6 | a 2-hop chain `a → b → c` mixing relative and absolute links | resolves to `c` |
| O7 | `/usr/bin/java` stub whose version output is the stub text | E9 → Check Failed (not Current) |
| O8 | `/usr/bin/git`, version `2.39.5` | `system(Command Line Tools)` → Blocked |
| O9 | a `{HOME}/.local/share/mise/shims/node` script | `versionManager(mise)` → Blocked |
| O10 | `{HOME}/.local/bin/browser-use → ../share/uv/tools/browser-use/bin/browser-use` | `uvTool(browser-use)` |
| O11 | a pipx venv symlink | `pipx(name)` |
| O12 | `{HOME}/.cargo/bin/cargo` with the same inode as `rustup` / `{HOME}/.cargo/bin/rg` listed in `.crates2.json` | `selfUpdater(rustup)` / `cargo(ripgrep)` |
| O13 | `{BREW}/bin/foo → ../Caskroom/foo/1.2.3/foo` | `brewCask(foo)` |
| O14 | PATH with duplicate entries | `whence` duplicates are deduped; active is still the first |
| O15 | a dangling link / a symlink loop | `ResolveError` → Check Failed, no crash |
| O16 | the binary or one of its ancestors is world-writable (`/tmp/x`), or owned by another uid | Blocked(`untrustedPath`) |
| O17 | the `cargo` and `rustup` rows resolve to the same `realPath` | one `DuplicateGroup`, "Same install" |
| O18 | the npm prefix's `lib/node_modules` is not writable | Blocked(`needsPrivilege`); no `sudo` anywhere |
| O19 | the catalog declares `npm: @anthropic-ai/claude-code`, but the path package is `evil-pkg` | Blocked(`ownerMismatch`) |
| O20 | `{Cellar}2/x/1.0/bin/x`, a sibling that isn't the Cellar | not `brewFormula` (component match) |
| O21 | `dart` at `<flutter>/bin/dart` | `bundledWith(flutter)` → Blocked |

*A: app owner resolution* → `AppOwnerResolverTests`

| # | Bundle | Expected |
|---|---|---|
| A1 | has `_MASReceipt/receipt`; iTunes fixture version newer | `appStore` → Update Available with a handoff spec |
| A2 | in the installed-cask index (openclaw), bundle `2026.9.5`, cask `2026.9.5`, record `2026.1.23` | Current (**G8**: the real bundle version wins) |
| A3 | the same with bundle `2026.1.23` | Update Available; argv includes `--greedy` |
| A4 | has `SUFeedURL`; the appcast has a default-channel item `1.5.0` (build 150), a beta item `1.6.0-beta` (`sparkle:channel`), an item with `minimumSystemVersion 99.0`, and a delta | latest = `1.5.0`, compared by build |
| A5 | `http:` feed / the feed returns 500 | Check Failed / Check Failed |
| A6 | has `Squirrel.framework`, and the catalog has `brewCask: cursor` (API fixture newer) | `selfUpdatingApp` → Update Available (handoff) |
| A7 | Squirrel with no cask oracle | Blocked(`noReadOnlyLatestSource`) |
| A8 | two copies (`/Applications`, `~/Applications`) | the first configured folder is active; the other is competing |

*F: failures fail closed (G2)* → `CheckEngineTests`, with a fake strategy

| # | Injected failure | Expected |
|---|---|---|
| F1 | `latest()` throws `.transient` (offline, non-zero exit, empty output, malformed JSON) | Check Failed, not selectable |
| F2 | timeout | Check Failed |
| F3 | `.unsupported` | Blocked(`noReadOnlyLatestSource`) |
| F4 | no strategy for the owner | Blocked; **never** Current |
| F5 | current version incomparable with latest | Check Failed |
| F6 | `command()` throws blocked | Blocked |
| F7 | any check run | the fake environment recorded no `CommandSpec`; every query factory's argv is free of mutating verbs |
| F8 | snoozed or ignored | `unknown` + message, never Current (Phase 0 parity) |

*S: selection* → `SelectionRulesTests`

| # | Case | Expected |
|---|---|---|
| S1 | each `ItemStatus` against `selectAllUpdates`, `checkAll` auto-select and the CLI `--update-all --yes` | only `updateAvailable` gets selected |
| S2 | Retry on `error` / `failedVerification` / `updatePending` | re-check; select and open the dry-run only if the result is Update Available |
| S3 | CLI `--update <gated bulk id> --yes` / `<gated privileged id> --yes` / `<blocked id> --yes` | runs / refused / refused |
| S4 | pinned `1.2.0`, latest `1.3.0` | Gated(`pinned`) |

*C: classifier* → `CommandShapeClassifierTests`

| # | Command | Risks |
|---|---|---|
| C1 | `npm install -g foo@1.2.3`; `brew upgrade gh`; `gem update --system`; `gem update cocoapods`; `mise self-update`; `brew upgrade --cask --greedy cursor` | ∅ (single) |
| C2 | `npm update -g`; `npm -g update`; `brew upgrade`; `brew upgrade --cask`; `gem update`; `mise upgrade`; `mas upgrade`; `pipx upgrade-all`; `uv tool upgrade --all`; `yarn global upgrade`; `pnpm up -g`; `softwareupdate -ia`; `npx skills update` | bulk |
| C3 | `brew update && brew upgrade` | bulk + chained |
| C4 | `pip3 list --outdated --format=freeze \| cut -d= -f1 \| xargs -n1 pip3 install -U` | bulk |
| C5 | `curl -fsSL https://x/i.sh \| bash`; `\| zsh`; `\| /bin/bash`; `wget -qO- … \| sh`; `bash <(curl -fsSL …)`; `sh -c "$(curl -fsSL …)"`; `eval "$(curl …)"`; `source <(curl …)` | remoteScript |
| C6 | `curl … \| sudo bash` | remoteScript + privileged |
| C7 | `sudo npm i -g x`; `osascript -e 'do shell script "x" with administrator privileges'` | privileged |
| C8 | `rm -rf ~/x`; `git reset --hard`; `diskutil eraseDisk …` | destructive |
| C9 | `a \|\| b`; `a; b`; `a && b`; `a 2>/dev/null`; `a &>/dev/null`; `a >/dev/null 2>&1`; `for d in …; do …; done`; `echo "unterminated` | fallbackChain; chained; chained; suppressedErrors ×3; controlFlow; unparseable |
| C10 | `echo "a \|\| b; c"`; `git commit -m 'x; y'` | ∅ (operators inside quotes) |
| C11 | `checkRunsUpdate("npm install -g --dry-run yarn@latest", "npm install -g yarn@latest")`; `("npm outdated -g yarn", "npm install -g yarn@latest")` | true; false |
| C12 | every typed `CommandSpec` from the strategy fixtures | `isSingle` |
| C13 | import a config whose custom item has `reviewedCommandHash` set | the hash is stripped → Gated(`needsReview`) |

*L: L3 and execution* → `ExecutionPlanTests`

| # | Scenario | Expected |
|---|---|---|
| L1 | Security's probe: plan `[a, b]` where `a` sleeps; while `a` runs, flip `b` to `notInstalled` or swap its owner | `b` is skipped with "changed since you confirmed"; neither its update nor its install runs |
| L2 | plan `[node(brew), codex(npm)]`; the node update moves the prefix realpath | codex is skipped (fingerprint changed) |
| L3 | `checkAll()` while `isUpdating` (toolbar, status bar, scheduler and wake paths) | no-op + log; `items` unchanged |
| L4 | `updateSelected` while `isChecking` | refused + log |
| L5 | the command exits 0, re-read version unchanged | `failedVerification` with evidence, including the command and the before/after versions |
| L6 | a handoff exits 0 | `updatePending` |
| L7 | `DryRunEntry.command` versus the command that was run | byte-for-byte equal (`displayString`) |

### 8. Phase 0 backlog mapping (from TIF-3)

| Backlog item | Where it lands |
|---|---|
| L3 | §6.4, T17 |
| Command-shape classifier, token-level lint | §5, T4–T5 |
| Needs-review badge (S3), `#if DEBUG` hook, hermetic `loadConfigs` tests, "all changed" log | T5, T0 |
| flutter/composer silent OK when the current-version parse fails | fixed by design: the self-updater strategies make a failed current parse Check Failed (T15) |
| SHA-as-version (`impeccable`) | `GitRepoStrategy` (T15) |
| Duplicate `hasFallbackChain` | deleted in T5 |
| Count strings shown as versions | D7 aggregates (T16) |
| Duplicate rows | same-install groups in T16. Rows for the same tool under different identities are Phase 2. |
| ~3m44s check | Phase 4. Phase 1 must not make it worse: one batched `whence`, one cask index per run, per-run HTTP cache, 20 s / 10 s timeouts. |

### 9. Hand-offs after Stage 2

- **Code Reviewer:** both PRs.
- **Security Reviewer:** PR-B, specifically §6, the classifier, and running `CommandSpec`s without a shell.
- **QA:** after PR-B, re-run defects 2, 5 and 8 read-only with `--check --json`. The owner fields should show:
  - `claude` → nativeInstaller
  - `codex` / `gemini` → npm with the nvm prefix, and `gemini` listing `/usr/local` as competing
  - `gh` → brewFormula
  - `java` → Check Failed
  - `node` → Blocked (nvm)
- **Content & Terminology:** the four new status labels are proposals (Current / Needs you / Can't update here / Didn't update).
