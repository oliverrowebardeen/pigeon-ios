# Compact Envelope Wire Format

Binary envelope format for Pigeon messages over LoRa. Used instead of JSON to fit encrypted payloads within Meshtastic's ~230-byte LoRa limit.

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

### Gateway bridging (firmware)

To bridge a direct envelope to the relay server, firmware must:
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

- **Direct:** Standard Pigeon ECDH — sender private key + recipient public key derive shared secret via X25519, HKDF-SHA256 key derivation, AES-256-GCM encryption.
- **Group:** Group symmetric key (AES-256-GCM). Key identified by `groupID` + `epoch`. Epoch increments on membership changes.

## Size Budget

| Component | Direct | Group |
|-----------|--------|-------|
| Compact header | 114 B | 84 B |
| Max ciphertext | ~116 B | ~146 B |
| **Total LoRa payload** | **~230 B** | **~230 B** |

Plaintext is slightly smaller than ciphertext due to WirePayloadV2 JSON encoding before encryption.

## Version History

| Version | Changes |
|---------|---------|
| 1 | Initial format with timestamp field |
