# Contributing to Pigeon

Thanks for your interest in contributing to Pigeon. This guide will help you get set up and submit your first pull request.

## Getting Started

**Prerequisites:**

- Xcode 26.0+
- No Apple Developer account is required for simulator builds. Physical devices need signing setup.

**Setup:**

1. Clone the repo.
2. Open `Pigeon.xcodeproj` in Xcode.

That's it -- there are zero external dependencies to install.

## Local Configuration

To build and run on a physical device, create a file called `Pigeon.local.xcconfig` in the project root:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PIGEON_BUNDLE_IDENTIFIER = com.example.yourname.Pigeon
```

Relay and bridge features are disabled by default in source builds. If you want them for local development, add:

```xcconfig
PIGEON_RELAY_ENABLED = YES
PIGEON_RELAY_WEBSOCKET_URL = ws:/$()/127.0.0.1:8080/v1/ws
```

Replace `YOUR_TEAM_ID` with your Apple Developer Team ID and choose a unique bundle identifier for your team. The app, test target, and profile URL type use this identifier. Push notifications also require matching relay APNS configuration. The `$()` prevents `//` from starting an xcconfig comment. Use your relay machine's LAN address for physical devices, or `wss:/$()/your-host/v1/ws` for a TLS endpoint. This file is gitignored and will not be committed.

## Running on Simulator

Build from the command line:

```bash
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Or just hit Run in Xcode with a simulator target selected.

**Note:** BLE features do not work on the iOS Simulator. You need 2+ physical iPhones to test mesh networking.

## Protocol References

- `docs/relay-and-bridge-protocol.md`
- `docs/compact-envelope-spec.md`

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
