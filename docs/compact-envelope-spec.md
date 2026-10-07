# Compact Envelope Wire Format

Binary envelope format for Pigeon messages over LoRa. It replaces the outer JSON envelope, but does not shrink the encrypted `WirePayloadV2` JSON. Current signed message payloads exceed the single-packet LoRa budget; these codecs alone do not provide working chat delivery over Meshtastic.

## Meshtastic Transport

- **Portnum:** 256 (`PRIVATE_APP`) — standard Meshtastic portnum for private application data
- **Destination:** `0xFFFFFFFF` (broadcast — all nodes relay)
- **Hop limit:** 3
- **BLE framing:** `[marker:2B big-endian 0x94C3][length:2B big-endian][protobuf ToRadio]`
- **Protobuf:** Manual codec for `ToRadio`/`FromRadio`/`MeshPacket`/`Data` (see `MeshtasticProtobuf.swift`)

The compact envelope is the `payload` field inside `MeshPacket.Data` with portnum 256.

## Direct Envelope (1:1 messages)

114 bytes header + variable ciphertext.

```
Offset  Size  Field              Encoding
──────  ────  ─────              ────────
0       1     version            uint8 (currently 1)
1       1     flags              uint8 (0x00 = direct)
2       16    messageID          UUID bytes (big-endian)
18      4     timestamp          uint32 epoch seconds (little-endian)
22      32    senderPublicKey    raw X25519 public key
54      32    recipientPublicKey raw X25519 public key
86      12    nonce              AES-256-GCM nonce
98      16    tag                AES-256-GCM authentication tag
114     N     ciphertext         AES-256-GCM encrypted payload
```

### Proposed gateway bridging (not implemented)

The following describes routing metadata a gateway would need. The current iOS relay receiver expects a JSON `MessageEnvelope`, so sending a compact envelope as `envelope_b64` is insufficient without a compatible conversion or receiver change:
1. Read `messageID` at bytes 2-17 (UUID for relay `message_id` field)
2. Read `recipientPublicKey` at bytes 54-85 (SHA-256 hash for relay `recipient_hash_hex`)
3. Construct the 48-byte Pigeon routing header: `[messageID:16B][SHA256(recipientPublicKey):32B]`
4. Base64-encode the full compact envelope as `envelope_b64`
5. Send to relay as `msg_send` JSON frame

## Group Broadcast Envelope (group messages)

84 bytes header + variable ciphertext.

```
Offset  Size  Field              Encoding
──────  ────  ─────              ────────
0       1     version            uint8 (currently 1)
1       1     flags              uint8 (0x01 = group)
2       16    groupID            UUID bytes (big-endian)
18      2     epoch              uint16 key epoch (big-endian)
20      4     timestamp          uint32 epoch seconds (little-endian)
24      32    senderPublicKey    raw X25519 public key
56      12    nonce              AES-256-GCM nonce
68      16    tag                AES-256-GCM authentication tag
84      N     ciphertext         AES-256-GCM encrypted payload (group symmetric key)
```

### Gateway bridging: NOT SUPPORTED

Group envelopes cannot be bridged to the relay server. The relay routes by single `recipient_hash_hex` — there is no fan-out. Group messages over LoRa stay on the LoRa mesh.

## Type Detection

Check byte 1 (flags):
- `0x00` = direct envelope
- `0x01` = group broadcast envelope

## Encryption

- **Direct:** Sealed sender uses an ephemeral sender private key and the recipient public key for X25519, HKDF-SHA256, and AES-256-GCM. The header's `senderPublicKey` is ephemeral; the signed payload contains the long-term sender identity.
- **Group:** Group symmetric key (AES-256-GCM). Key identified by `groupID` + `epoch`. Epoch increments on membership changes.

## Size Budget

| Component | Direct | Group |
|-----------|--------|-------|
| Compact header | 114 B | 84 B |
| Max ciphertext | ~116 B | ~146 B |
| **Total LoRa payload** | **~230 B** | **~230 B** |

AES-GCM ciphertext has the same length as the encoded plaintext; the nonce and tag are already counted in the header. The plaintext here is the entire signed `WirePayloadV2` JSON, not just the text typed by the user. Two base64-encoded 32-byte public keys and a base64-encoded 64-byte signature alone take 176 bytes, before JSON field names or message content. That exceeds both budgets above. A smaller authenticated payload format or fragmentation is required. The dedicated Pigeon-node send path allows 233 bytes rather than 230; this does not resolve the payload-size limitation.

## Version History

| Version | Changes |
|---------|---------|
| 1 | Initial format with timestamp field |
