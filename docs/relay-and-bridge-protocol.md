# Relay And Bridge Protocol

This document covers the contributor-facing wire contracts for the internet relay path, bridge mode, and signed message payloads.

## Identity Layers

Pigeon uses two Curve25519 keypairs per device:

- `identity.privateKey` / `identity.publicKey`: X25519 key agreement for envelope encryption and relay authentication.
- `identity.signingPrivateKey` / `identity.signingPublicKey`: Ed25519 signatures for authenticated `WirePayloadV2` bodies.

Every `WirePayloadV2` sent over BLE, relay, or a bridge must be signed. Unsigned payloads are rejected.

## Direct Envelope Format

All point-to-point transport paths carry a `MessageEnvelope`:

```swift
struct MessageEnvelope {
    let id: UUID
    let senderPublicKey: Data
    let recipientPublicKey: Data
    let timestamp: Date
    let nonce: Data
    let ciphertext: Data
    let tag: Data
    var hopCount: UInt8
    let ttl: UInt8
}
```

For sealed sender, `senderPublicKey` is an ephemeral X25519 public key, not the sender's long-term identity. The real sender identity lives inside the decrypted `WirePayloadV2`.

## Signed Payload Contract

`WirePayloadV2` is the decrypted JSON payload inside the envelope. The important integrity fields are:

- `senderPublicKey`: the sender's long-term X25519 identity key.
- `senderSigningPublicKey`: the sender's Ed25519 public key.
- `signature`: Ed25519 signature over the payload with both signature fields cleared, except that `senderSigningPublicKey` is included in the signed bytes.

Verification flow:

1. Decrypt the envelope.
2. Decode `WirePayloadV2`.
3. Re-serialize the payload without `signature`.
4. Verify `signature` with `senderSigningPublicKey`.
5. Pin the signing key to `senderPublicKey` on first contact; reject future mismatches.

## Relay WebSocket Roles

Relay endpoint: `/v1/ws`

The first client frame fixes the socket role:

- `auth_hello` => authenticated receive connection
- `msg_send` => anonymous send connection

Receive connections authenticate with X25519 challenge/response:

1. client -> relay: `auth_hello { client_pubkey_b64 }`
2. relay -> client: `auth_challenge { challenge_id, server_pubkey_b64, nonce_b64, issued_at_ms, expires_at_ms }`
3. client -> relay: `auth_prove { challenge_id, proof_b64 }`
4. relay -> client: `auth_ok { identity_hash_hex, session_expires_at_ms }`

Anonymous send connections skip authentication and send only:

```json
{
  "type": "msg_send",
  "req_id": "<message-id>",
  "payload": {
    "message_id": "<message-id>",
    "recipient_hash_hex": "<sha256(recipientPublicKey)>",
    "envelope_b64": "<base64-encoded MessageEnvelope bytes>"
  }
}
```

The relay answers with `msg_accepted` or `error`, and authenticated recipients receive `msg_deliver`.

## Bridge Mode

Bridge mode uses BLE control frames to proxy raw relay WebSocket traffic through a nearby internet-connected phone.

Important property: bridge mode still uses two logical relay sessions:

- an authenticated receive tunnel for `auth_hello` / delivery / push registration
- a separate anonymous send tunnel whose first tunneled frame is `msg_send`

That separation keeps sealed sender intact even when a phone is bridging on behalf of another device.

Bridge control frames:

- `bridge_status`
- `tunnel_open`
- `tunnel_opened`
- `tunnel_data`
- `tunnel_close`
- `tunnel_error`
- `ping`
- `pong`

`tunnel_data.payload_b64` contains UTF-8 JSON text for the proxied relay frame.

## Group Payloads

Group traffic still uses `WirePayloadV2`, but the group body is nested:

- `eventType = group_message` or `group_reaction`
- `groupEncrypted` contains AES-GCM ciphertext encrypted with the current group epoch key
- the inner plaintext is `GroupInnerPayload`

Group key distribution uses signed `group_key_share` payloads and is only accepted from the pinned group owner identity.
