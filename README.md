# Pigeon

Pigeon is an experimental encrypted messenger for iOS, with Bluetooth Low Energy mesh routing, an optional internet relay, and LoRa integration under development. Nearby phones can exchange and forward messages without internet. With a configured relay, an internet-connected phone can also bridge traffic for nearby phones. Intermediaries forward encrypted message content; connectivity, background operation, and delivery depend on the devices and network. Pigeon has not received an independent security audit.

## Try It

**Pre-beta: no TestFlight build is currently available.** Developers can build from source using the instructions below. Testing Bluetooth messaging requires two physical iPhones; simulator tests do not demonstrate radio delivery.

## Explore the project

| Component | Purpose | Stack |
| --- | --- | --- |
| **This repository** | Mobile UI, identities, encrypted messages, and transport selection | Swift, SwiftUI, CoreBluetooth, CryptoKit, SwiftData |
| [Relay](https://github.com/oliverrowebardeen/pigeon-relay) | Authenticated receive sessions and queued encrypted delivery | Rust, Tokio, Axum, WebSockets |
| [Mesh node](https://github.com/oliverrowebardeen/pigeon-firmware) | Bridge phones to LoRa radios and optional WiFi | C++, ESP32-S3, PlatformIO |

Start with the simulator test command below, then read the [engineering notes](docs/engineering-notes.md). This is an experimental project: automated checks verify source behavior, while Bluetooth/radio claims require a recorded device test.

## Features

- **BLE mesh networking** — Messages hop across nearby iPhones using Bluetooth Low Energy. Multi-hop relay with TTL-based forwarding and deduplication.
- **End-to-end encryption** — Curve25519 ECDH key agreement, AES-256-GCM authenticated encryption, HKDF-SHA256 key derivation. Keys generated on-device and stored in the iOS Keychain.
- **Internet relay fallback** — When both devices have internet, messages route through an encrypted WebSocket relay with X25519 challenge-response authentication.
- **Bridge mode** — A phone with internet access can relay messages for nearby offline phones, bridging BLE mesh to the internet relay transparently without adding the sender identity to the relay send protocol.
- **Experimental Meshtastic integration** — BLE discovery, a handwritten protobuf codec, and compact envelope codecs for stock Meshtastic nodes and Pigeon nodes in Meshtastic mode. Current signed message payloads exceed the single-packet LoRa budget; a smaller authenticated payload format or fragmentation is needed before this path supports normal chats. Hardware interoperability remains to be validated. Uses Meshtastic portnum 256; other apps may observe radio traffic.
- **Group messaging** — Symmetric key encryption with epoch-based key rotation on membership changes. Owner-controlled member management. Groups use single-broadcast envelopes over LoRa instead of per-member fan-out.
- **Push notifications** — APNS integration through the relay server. The server sends push payloads without ever seeing message content.
- **QR code identity sharing** — Share your Pigeon ID via QR code for easy peer discovery.
- **Zero external dependencies** — Built entirely on Apple frameworks: CoreBluetooth, CryptoKit, SwiftData, SwiftUI. Manual protobuf codec for Meshtastic BLE — no generated code or external libraries.

## Architecture

```
                    BLE Mesh (no internet needed)
                    ┌──────────────────────────┐
                    │                          │
  ┌─────────┐      │   ┌─────────┐            │      ┌─────────┐
  │Phone A  │◄─BLE─┼──►│ Relay   │◄───BLE────►┼─────►│Phone B  │
  │(sender) │      │   │ Phone   │             │      │(recipient)
  └────┬────┘      │   └─────────┘             │      └────┬────┘
       │           └──────────────────────────┘            │
       │                                                   │
       │           Internet Relay (when available)         │
       │           ┌──────────────────────────┐            │
       └───WSS────►│  Relay Server            │◄───WSS────┘
                   │  (opaque — never sees    │
                   │   message plaintext)   │
                   └──────────────────────────┘

                    Bridge Mode (hybrid)
  ┌─────────┐      ┌─────────┐      ┌──────────────┐      ┌─────────┐
  │Phone A  │─BLE─►│ Bridge  │─WSS─►│ Relay Server │─WSS─►│Phone B  │
  │(offline)│      │ Phone   │      │ (opaque)     │      │(online) │
  └─────────┘      │(online) │      └──────────────┘      └─────────┘
                   └─────────┘

                    Meshtastic LoRa (experimental path)
  ┌─────────┐      ┌─────────────┐      ┌─────────────┐      ┌─────────┐
  │Phone A  │─BLE─►│ Meshtastic  │─LoRa►│ Meshtastic  │◄─BLE─│Phone B  │
  │(sender) │      │ Node        │      │ Node        │      │(recipient)
  └─────────┘      └─────────────┘      └─────────────┘      └─────────┘

  Encryption: E2E at every path. Relay server forwards AES-256-GCM
  ciphertext without decryption keys. Bridge phones forward opaque
  encrypted frames — they cannot read the content either. Meshtastic
  nodes relay opaque compact envelopes — they cannot read content.
```

## Transport Modes

Pigeon automatically selects the best available transport:

1. **BLE Direct** — Both phones are within Bluetooth range (range depends on the devices and surroundings). Messages transfer directly over BLE.
2. **BLE Mesh** — Phones are out of direct range but other Pigeon devices are nearby. Messages hop through intermediate phones (up to 5 hops by default).
3. **Internet Relay** — Both phones have internet. Messages route through the relay server via encrypted WebSocket. The server authenticates via X25519 challenge-response — no accounts, no passwords.
4. **Bridge** — One phone has internet, the other doesn't. The internet-connected phone acts as a bridge, forwarding BLE messages to the relay server and vice versa. Selection uses hysteresis to prevent thrashing between candidates.
5. **Pigeon Node (Meshtastic Mode)** — A Pigeon node advertising `loraMode: "meshtastic"` accepts compact envelopes over Pigeon BLE. The app checks a 233-byte packet limit in its dedicated send path. Normal signed payloads exceed this limit; selecting this mode does not establish working chat delivery.
6. **Stock Meshtastic LoRa** — The stock-node send path checks a 230-byte packet limit, including the compact header (114 bytes for direct envelopes, 84 for groups). Normal signed payloads exceed the remaining budget. The app uses Meshtastic portnum 256 (`PRIVATE_APP`) and ignores other application ports.

Transport switching is automatic and transparent. The app shows the current transport state in the UI.

## Protocol Docs

- [Relay and bridge protocol](docs/relay-and-bridge-protocol.md) — signed `WirePayloadV2`, relay WebSocket roles, and bridge tunnel framing
- [Compact envelope spec](docs/compact-envelope-spec.md) — binary envelope format used for Meshtastic LoRa transport

## Encryption

Every message is end-to-end encrypted before it leaves the sending device:

- **Identity** — Each device generates a long-term X25519 keypair plus an Ed25519 signing keypair on first launch. Private keys are stored in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`). The X25519 public key serves as the device identity; the Ed25519 key authenticates payload contents.
- **Key agreement** — ECDH (Elliptic Curve Diffie-Hellman) with Curve25519 derives a shared secret between sender and recipient.
- **Key derivation** — HKDF-SHA256 derives a 256-bit symmetric key from the shared secret.
- **Encryption** — AES-256-GCM with a fresh random nonce per message. Provides authenticated encryption (confidentiality + integrity + authentication).
- **Payload signatures** — Every outgoing `WirePayloadV2` body is Ed25519-signed before encryption. Recipients verify signatures after decryption, reject unsigned payloads, and pin the Ed25519 key to the X25519 identity on first contact. Relay servers and bridge phones cannot inspect or verify the encrypted signature. See [docs/relay-and-bridge-protocol.md](docs/relay-and-bridge-protocol.md) for the signed-bytes layout.
- **Sealed sender** — Direct envelopes use ephemeral Curve25519 sender keys. Visible fields include the recipient public key, its routing hash, an ephemeral public key, message ID, timestamp, and ciphertext. The envelope omits the sender's long-term identity, but network addresses, timing, and message sizes can still correlate activity. Compact group headers include the sender's public key. Intermediaries cannot decrypt message content under the documented key and trust assumptions.
- **Group encryption** — Groups use symmetric key encryption with epoch-based rotation. When members are added or removed, the group key rotates and is redistributed to active members.

## Building

### Prerequisites

- macOS with **Xcode 26.0+** and an installed iOS Simulator runtime
- iOS 26.0+ deployment target
- No Apple Developer account is required for simulator builds; physical devices need signing setup.

### Clone and Build

```bash
git clone https://github.com/oliverrowebardeen/pigeon-ios.git
cd pigeon-ios
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO build
```

Or open `Pigeon.xcodeproj` in Xcode and hit Run.

If the named simulator is unavailable for Xcode's latest runtime, list installed devices with `xcrun simctl list devices available` and specify its OS explicitly, for example `-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.1'`.

### Local Relay / Bridge Configuration

Internet relay and bridge features are opt-in in source builds. No relay endpoint is bundled.

Create `Pigeon.local.xcconfig` in the project root if you want relay features enabled locally:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
PIGEON_RELAY_ENABLED = YES
PIGEON_RELAY_WEBSOCKET_URL = ws:/$()/127.0.0.1:8080/v1/ws
```

The `$()` keeps `//` from becoming an xcconfig comment. This resolves to `ws://127.0.0.1:8080/v1/ws`. Use your relay machine’s LAN address for physical devices and `wss:/$()/your-host/v1/ws` for a TLS endpoint.

### Code Signing for Physical Devices

BLE doesn't work on the iOS Simulator — you need physical iPhones. To build on a device:

1. Create `Pigeon.local.xcconfig` in the project root:
   ```xcconfig
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   PIGEON_BUNDLE_IDENTIFIER = com.example.yourname.Pigeon
   ```
2. Add `PIGEON_RELAY_ENABLED` / `PIGEON_RELAY_WEBSOCKET_URL` there too if you want relay or bridge mode during local testing.
3. This file is gitignored. Find your Team ID in [Apple Developer > Membership](https://developer.apple.com/account) and choose a unique bundle identifier for your team. Push notifications require matching APNS credentials and bundle configuration on your relay.
4. Build and run on your device from Xcode.

You'll need **2+ iPhones** to test BLE mesh messaging.

## Current Status

### Implemented

- BLE mesh messaging with multi-hop relay and deduplication
- End-to-end encryption (Curve25519 + AES-256-GCM) with sealed sender
- Internet relay transport with WebSocket and X25519 auth
- Bridge mode (anonymous send tunnel + authenticated receive tunnel)
- Experimental Meshtastic BLE integration and compact envelope codecs (signed-message size limitation below)
- Group messaging with epoch-based key rotation
- Push notifications via APNS
- QR code identity sharing
- Contact management with trust verification
- Message reactions and replies
- Read receipts
- Automatic transport switching (BLE > Pigeon mesh > relay > Pigeon meshtastic > stock Meshtastic > flood)

### Planned

- Authenticated payloads that fit Meshtastic packets, or LoRa fragmentation
- Meshtastic gateway bridging (LoRa-to-relay via firmware)
- Connection priority state machine (auto-switch between Pigeon and Meshtastic nodes)
- Android client
- Satellite transport
- Desktop client
- File/image sharing
- Voice messages

## Validation and Security

Run the unit and protocol tests on a simulator:

```sh
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGN_IDENTITY=- test
```

Keep simulator code signing enabled so the test host can use Keychain; `CODE_SIGN_IDENTITY=-` uses ad-hoc signing without a developer account. Do not pass `CODE_SIGNING_ALLOWED=NO` to the test command. Bluetooth and LoRa operation still require physical devices. CI builds the app, runs tests, and scans Git history for exposed secrets. See [SECURITY.md](SECURITY.md) for reporting and the threat model.

## Known Limitations

- **Security status**: Experimental software, without an independent cryptographic audit. Key pinning uses trust on first use. Sealed sender does not prevent traffic analysis or provide forward secrecy after recipient-key compromise. Local message history is stored in SwiftData under iOS platform protections, not separately encrypted by Pigeon.
- **BLE reassembly**: At most 32 incomplete transfers per message/control channel, 256 chunks per transfer, and 480 bytes per chunk. Invalid or inconsistent chunks are discarded.
- **BLE range**: Depends on the devices, surroundings, and iOS state; no range guarantee.
- **Meshtastic message size**: The 230/233-byte packet limits include encryption and protocol overhead. Signed `WirePayloadV2` JSON exceeds that budget even for short text. The UI's text counter does not account for the full payload and is not a delivery guarantee. See the [compact envelope spec](docs/compact-envelope-spec.md).
- **Meshtastic gateway**: LoRa-to-relay bridging not yet implemented. Meshtastic messages stay on the LoRa mesh.
- **Meshtastic groups**: Group broadcast over LoRa uses a single envelope (efficient) but cannot be bridged to the relay server (relay is point-to-point only).
- **iOS only**: No Android or desktop client yet
- **BLE connections**: Capacity and background availability depend on the device and iOS.
- **Message size**: BLE MTU limits chunks to 480 bytes with 22-byte headers
- **Mesh TTL**: Default 5 hops. Messages held for relay expire after 1 hour.
- **Simulator**: BLE features do not work on the iOS Simulator. Testing requires physical devices.
- **Bundle ID**: Source builds default to `org.example.Pigeon`. Set `PIGEON_BUNDLE_IDENTIFIER` in `Pigeon.local.xcconfig` for device signing. Changing the identifier creates a separate app installation and does not migrate an existing installation's identity or messages.

## Related

- **[pigeon-relay](https://github.com/oliverrowebardeen/pigeon-relay)** — The encrypted relay server (Rust). Handles WebSocket transport, X25519 authentication, message queuing, and APNS push delivery. Forwards client-encrypted messages without decrypting them.
- **[pigeon-firmware](https://github.com/oliverrowebardeen/pigeon-firmware)** — ESP32 firmware for dedicated Pigeon mesh nodes. Custom LoRa protocol, BLE GATT server, WiFi bridge to relay. Meshtastic LoRa integration in progress.

## License

[MIT](LICENSE) for Pigeon software. See [third-party notices](THIRD_PARTY_NOTICES.md) for protocol references and the separately licensed code of conduct.
