# Contributing to Pigeon

Thanks for your interest in contributing to Pigeon. This guide will help you get set up and submit your first pull request.

## Getting Started

**Prerequisites:**

- Xcode 26.0+
- An Apple Developer account (a free account works for simulator builds)

**Setup:**

1. Clone the repo.
2. Open `Pigeon.xcodeproj` in Xcode.

That's it -- there are zero external dependencies to install.

## Setting Your Team ID

To build and run on a physical device, create a file called `Pigeon.local.xcconfig` in the project root:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Replace `YOUR_TEAM_ID` with your Apple Developer Team ID. This file is gitignored and will not be committed.

## Running on Simulator

Build from the command line:

```bash
xcodebuild -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Or just hit Run in Xcode with a simulator target selected.

**Note:** BLE features do not work on the iOS Simulator. You need 2+ physical iPhones to test mesh networking.

## Submitting a Pull Request

1. Fork the repo.
2. Create a feature branch from `main`.
3. Make your changes.
4. Open a pull request against `main`.

Keep PRs focused -- one feature or fix per PR.

## Code Style

- **Zero force-unwraps** (`!`) -- use `guard let`, `if let`, or `try/catch` instead.
- **Strict Swift concurrency** -- `@MainActor` by default, explicit `nonisolated` and `Sendable` for cross-isolation types.
- **No external dependencies** -- Apple frameworks only.
- **Follow existing naming conventions** -- camelCase for variables and functions, PascalCase for types.

## Reporting Issues

Use GitHub Issues. Please include:

- What you expected to happen.
- What actually happened.
- iOS version.
- Device model.
