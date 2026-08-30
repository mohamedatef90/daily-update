# Repository Guidelines

## Project Structure & Module Organization

Daily Update is a Swift Package Manager macOS 13+ app. Its executable target is
`Sources/DailyUpdate`. Keep code grouped by responsibility:

- `Models/` contains shared data types and settings models.
- `Services/` contains update detection, shell execution, persistence, scanning,
  scheduling, and app lifecycle behavior.
- `Views/` contains SwiftUI screens and reusable UI components.
- `Resources/` contains bundled runtime assets, notably `detectors.json` and
  `scripts/check-app-update.sh`.
- `Assets/AppIcon/` holds the source PNG and generated `.icns` icon.
- `scripts/` holds project automation, including app-bundle creation.

Place a new feature's model, service, and view in the corresponding folders;
avoid mixing UI work with shell or persistence logic.

## Build, Test, and Development Commands

- `swift build` compiles the debug executable for local development.
- `swift build -c release` produces the release binary in `.build/release`.
- `./scripts/build-app.sh` builds the release executable, regenerates the icon,
  and creates `DailyUpdate.app`.
- `open DailyUpdate.app` launches the bundled app after a build.
- `DailyUpdate.app/Contents/MacOS/DailyUpdate --check` runs an update check from
  the command line.

There is currently no test target. Run `swift build` before submitting changes,
and manually exercise the affected UI or CLI flow.

## Coding Style & Naming Conventions

Use four-space indentation and standard Swift formatting. Name types in
`UpperCamelCase`, properties and functions in `lowerCamelCase`, and keep one
primary type per file where practical. Use `// MARK: -` to separate meaningful
sections in larger types. Keep SwiftUI views focused on presentation; put side
effects and shell commands in services. Use descriptive JSON keys consistent
with the existing detector schema.

## Testing Guidelines

When adding tests, create a SwiftPM test target under `Tests/DailyUpdateTests`.
Name test files after the subject (for example, `DetectionServiceTests.swift`)
and methods as `test<ExpectedBehavior>()`. Prefer unit tests for command parsing,
configuration loading, and update-state decisions; manually verify macOS-only
integration behavior.

## Commit & Pull Request Guidelines

Recent commits use short, imperative summaries, e.g. `Document setup guide for
new users in README.` Keep each commit scoped to one change. Pull requests
should explain the user-visible result, list validation performed, link any
related issue, and include screenshots for SwiftUI changes. Do not commit
generated `.build/`, `DailyUpdate.app`, or iconset files.

## Configuration & Safety

User settings live outside the repository at
`~/Library/Application Support/DailyUpdate/settings.json`. Do not commit local
paths, credentials, or machine-specific detector settings. Treat commands from
detector configuration as user-impacting: validate arguments and preserve clear
error reporting.
