# Pigeon

Pigeon is an encrypted mesh messenger for iOS. It sends text messages between iPhones over Bluetooth Low Energy — works without internet or servers. Each device acts as both a client and a relay node, forwarding messages across nearby phones until they reach their destination. When internet is available, Pigeon can also route through an encrypted relay server, or use a nearby internet-connected phone as a bridge. The relay server never sees plaintext — it forwards opaque encrypted blobs.

## Try It

**[Download on TestFlight](https://testflight.apple.com)** — first 100 testers.

## Features

- **BLE mesh networking** — Messages hop across nearby iPhones using Bluetooth Low Energy. Multi-hop relay with TTL-based forwarding and deduplication.
- **End-to-end encryption** — Curve25519 ECDH key agreement, AES-256-GCM authenticated encryption, HKDF-SHA256 key derivation. Keys generated on-device and stored in the iOS Keychain.
- **Internet relay fallback** — When both devices have internet, messages route through an encrypted WebSocket relay with X25519 challenge-response authentication.
- **Bridge mode** — A phone with internet access can relay messages for nearby offline phones, bridging BLE mesh to the internet relay transparently while preserving sealed-sender anonymity.
- **Meshtastic LoRa support** — Long-range mesh messaging over LoRa radio. Connect directly to stock Meshtastic nodes via Meshtastic BLE, or use a Pigeon mesh node in Meshtastic mode for seamless interop. Compact binary wire format fits encrypted envelopes within LoRa payload limits. Uses Meshtastic portnum 256 — Pigeon traffic is invisible to other Meshtastic apps.
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
                   │   plaintext or sender)   │
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

1. **BLE Direct** — Both phones are within Bluetooth range (~50-100m). Messages transfer directly over BLE.
2. **BLE Mesh** — Phones are out of direct range but other Pigeon devices are nearby. Messages hop through intermediate phones (up to 5 hops by default).
3. **Internet Relay** — Both phones have internet. Messages route through the relay server via encrypted WebSocket. The server authenticates via X25519 challenge-response — no accounts, no passwords.
4. **Bridge** — One phone has internet, the other doesn't. The internet-connected phone acts as a bridge, forwarding BLE messages to the relay server and vice versa. Selection uses hysteresis to prevent thrashing between candidates.
5. **Pigeon Node (Meshtastic Mode)** — A Pigeon mesh node with `loraMode: "meshtastic"` bridges Pigeon BLE to Meshtastic LoRa. The phone sends compact binary envelopes over the Pigeon BLE protocol; the node relays them as Meshtastic packets. Interoperable with stock Meshtastic nodes on the same mesh.
6. **Stock Meshtastic LoRa** — Connect directly to any stock Meshtastic node via Meshtastic BLE for long-range mesh messaging over LoRa radio. Messages use a compact binary envelope format (114 bytes overhead) instead of JSON to fit within LoRa payload limits (~230 bytes). The app uses Meshtastic portnum 256 (PRIVATE_APP) — non-Pigeon Meshtastic traffic is ignored.

Transport switching is automatic and transparent. The app shows the current transport state in the UI.

## Protocol Docs

- [Relay and bridge protocol](docs/relay-and-bridge-protocol.md) — signed `WirePayloadV2`, relay WebSocket roles, and bridge tunnel framing
- [Compact envelope spec](docs/compact-envelope-spec.md) — binary envelope format used for Meshtastic LoRa transport

## Encryption

Every message is end-to-end encrypted before it leaves the sending device:

- **Identity** — Each device generates a Curve25519 keypair on first launch. The private key is stored in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlock`). The public key serves as the device identity.
- **Key agreement** — ECDH (Elliptic Curve Diffie-Hellman) with Curve25519 derives a shared secret between sender and recipient.
- **Key derivation** — HKDF-SHA256 derives a 256-bit symmetric key from the shared secret.
- **Encryption** — AES-256-GCM with a fresh random nonce per message. Provides authenticated encryption (confidentiality + integrity + authentication).
- **Sealed sender** — Messages use ephemeral Curve25519 keys so the relay server only sees the recipient's routing hash, an unlinkable ephemeral public key, and opaque ciphertext. It cannot identify the sender or decrypt content. Bridge phones similarly forward encrypted frames they cannot read.
- **Group encryption** — Groups use symmetric key encryption with epoch-based rotation. When members are added or removed, the group key rotates and is redistributed to active members.

## Building

### Prerequisites

- macOS with **Xcode 26.0+**
- iOS 26.0+ deployment target
- An Apple Developer account (free tier works for simulator builds)

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
PIGEON_RELAY_WEBSOCKET_URL = ws://127.0.0.1:8080/v1/ws
```

Use a LAN or public `ws://` / `wss://` URL instead of `127.0.0.1` when testing on physical devices.

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

### Built and Working

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

## Known Limitations

- **BLE range**: ~50-100 meters between devices, depending on environment
- **LoRa message size**: ~120 byte plaintext limit over Meshtastic (compact envelope overhead + LoRa payload cap). Short text messages only — no images or files via LoRa.
- **Meshtastic gateway**: LoRa-to-relay bridging not yet implemented. Meshtastic messages stay on the LoRa mesh.
- **Meshtastic groups**: Group broadcast over LoRa uses a single envelope (efficient) but cannot be bridged to the relay server (relay is point-to-point only).
- **iOS only**: No Android or desktop client yet
- **BLE connections**: iOS allows ~7 simultaneous BLE connections
- **Message size**: BLE MTU limits chunks to 480 bytes with 22-byte headers
- **Mesh TTL**: Default 5 hops. Messages held for relay expire after 1 hour.
- **Simulator**: BLE features do not work on the iOS Simulator. Testing requires physical devices.
- **Bundle ID**: Currently `com.example.Pigeon` — will be updated before App Store release.

## Related

- **[pigeon-relay](https://github.com/oliverrowebardeen/pigeon-relay)** — The encrypted relay server (Rust). Handles WebSocket transport, X25519 authentication, message queuing, and APNS push delivery. Zero-knowledge design — never decrypts messages.
- **[pigeon-firmware](https://github.com/oliverrowebardeen/pigeon-firmware)** — ESP32 firmware for dedicated Pigeon mesh nodes. Custom LoRa protocol, BLE GATT server, WiFi bridge to relay. Meshtastic LoRa integration in progress.

## License

[MIT](LICENSE)
