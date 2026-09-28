# Pigeon

Pigeon is an encrypted mesh messenger for iOS. It sends text messages between iPhones over Bluetooth Low Energy — works without internet or servers. Each device acts as both a client and a relay node, forwarding messages across nearby phones until they reach their destination. When internet is available, Pigeon can also route through an encrypted relay server, or use a nearby internet-connected phone as a bridge. The relay server never sees plaintext — it forwards opaque encrypted blobs.

## Try It

**[TestFlight invitation](https://testflight.apple.com)** — availability depends on the current build and capacity. Source builds work without joining the beta.

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
- **Meshtastic LoRa support** — Long-range mesh messaging over LoRa radio. Connect directly to stock Meshtastic nodes via Meshtastic BLE, or use a Pigeon mesh node in Meshtastic mode for seamless interop. Compact binary wire format fits encrypted envelopes within LoRa payload limits. Uses Meshtastic portnum 256 — Other apps may observe radio traffic; Pigeon message content remains encrypted.
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

                    Meshtastic LoRa (long-range, no internet)
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
5. **Pigeon Node (Meshtastic Mode)** — A Pigeon mesh node with `loraMode: "meshtastic"` bridges Pigeon BLE to Meshtastic LoRa. The phone sends compact binary envelopes over the Pigeon BLE protocol; the node relays them as Meshtastic packets. Interoperable with compatible Meshtastic nodes on the same channel and radio settings; verify your hardware and firmware combination.
6. **Stock Meshtastic LoRa** — Connect to a compatible stock Meshtastic node via Meshtastic BLE for long-range mesh messaging over LoRa radio. Messages use a compact binary envelope format (114 bytes overhead) instead of JSON to fit within LoRa payload limits (~230 bytes). The app uses Meshtastic portnum 256 (PRIVATE_APP) — non-Pigeon Meshtastic traffic is ignored.

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
- **Payload signatures** — Every `WirePayloadV2` body is Ed25519-signed by the sender before encryption. Relay, bridge phones, and recipients all reject unsigned payloads, and recipients pin the Ed25519 key to the X25519 identity on first contact so a later mismatch is treated as impersonation. See [docs/relay-and-bridge-protocol.md](docs/relay-and-bridge-protocol.md) for the canonical signed-bytes layout.
- **Sealed sender** — Messages use ephemeral Curve25519 keys so the relay server only sees the recipient's routing hash, an ephemeral public key, and opaque ciphertext. The envelope omits the sender identity, but network addresses, timing, and message sizes can still correlate activity. It cannot decrypt message content. Bridge phones similarly forward encrypted frames they cannot read.
- **Group encryption** — Groups use symmetric key encryption with epoch-based rotation. When members are added or removed, the group key rotates and is redistributed to active members.

## Building

### Prerequisites

- macOS with **Xcode 26.0+**
- iOS 26.0+ deployment target
- No Apple Developer account is required for simulator builds; physical devices need signing setup.

### Clone and Build

```bash
git clone https://github.com/oliverrowebardeen/pigeon-ios.git
cd pigeon-ios
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Or open `Pigeon.xcodeproj` in Xcode and hit Run.

### Local Relay / Bridge Configuration

Internet relay and bridge features are opt-in in source builds so contributors do not hit the production relay by default.

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
   ```
2. Add `PIGEON_RELAY_ENABLED` / `PIGEON_RELAY_WEBSOCKET_URL` there too if you want relay or bridge mode during local testing.
3. This file is gitignored. Find your Team ID in [Apple Developer > Membership](https://developer.apple.com/account).
4. Build and run on your device from Xcode.

You'll need **2+ iPhones** to test BLE mesh messaging.

## Current Status

### Implemented

- BLE mesh messaging with multi-hop relay and deduplication
- End-to-end encryption (Curve25519 + AES-256-GCM) with sealed sender
- Internet relay transport with WebSocket and X25519 auth
- Bridge mode (anonymous send tunnel + authenticated receive tunnel)
- Meshtastic LoRa transport (stock Meshtastic BLE + Pigeon node meshtastic mode, compact binary envelopes)
- Group messaging with epoch-based key rotation
- Push notifications via APNS
- QR code identity sharing
- Contact management with trust verification
- Message reactions and replies
- Read receipts
- Automatic transport switching (BLE > Pigeon mesh > relay > Pigeon meshtastic > stock Meshtastic > flood)

### Planned

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
xcodebuild -project Pigeon.xcodeproj -scheme Pigeon -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- test
```

Keep simulator code signing enabled so the test host can use Keychain. Bluetooth and LoRa operation still require physical devices. CI builds the app, runs tests, and scans Git history for exposed secrets. See [SECURITY.md](SECURITY.md) for reporting and the threat model.

## Known Limitations

- **Security status**: Experimental software, without an independent cryptographic audit. Key pinning uses trust on first use. Sealed sender does not prevent traffic analysis or provide forward secrecy after recipient-key compromise. Local message history is stored in SwiftData under iOS platform protections, not separately encrypted by Pigeon.
- **BLE reassembly**: At most 32 incomplete transfers per message/control channel, 256 chunks per transfer, and 480 bytes per chunk. Invalid or inconsistent chunks are discarded.
- **BLE range**: Depends on the devices, surroundings, and iOS state; no range guarantee.
- **LoRa message size**: ~120 byte plaintext limit over Meshtastic (compact envelope overhead + LoRa payload cap). Short text messages only — no images or files via LoRa.
- **Meshtastic gateway**: LoRa-to-relay bridging not yet implemented. Meshtastic messages stay on the LoRa mesh.
- **Meshtastic groups**: Group broadcast over LoRa uses a single envelope (efficient) but cannot be bridged to the relay server (relay is point-to-point only).
- **iOS only**: No Android or desktop client yet
- **BLE connections**: Capacity and background availability depend on the device and iOS.
- **Message size**: BLE MTU limits chunks to 480 bytes with 22-byte headers
- **Mesh TTL**: Default 5 hops. Messages held for relay expire after 1 hour.
- **Simulator**: BLE features do not work on the iOS Simulator. Testing requires physical devices.
- **Bundle ID**: Currently `com.example.Pigeon` — will be updated before App Store release.

## Related

- **[pigeon-relay](https://github.com/oliverrowebardeen/pigeon-relay)** — The encrypted relay server (Rust). Handles WebSocket transport, X25519 authentication, message queuing, and APNS push delivery. Forwards client-encrypted messages without decrypting them.
- **[pigeon-firmware](https://github.com/oliverrowebardeen/pigeon-firmware)** — ESP32 firmware for dedicated Pigeon mesh nodes. Custom LoRa protocol, BLE GATT server, WiFi bridge to relay. Meshtastic LoRa integration in progress.

## License

[MIT](LICENSE)
