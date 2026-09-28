# Engineering notes

Pigeon explores how a messaging client can use nearby phones, dedicated radio nodes, and an internet relay without giving those intermediaries plaintext message content. The three repositories form one system.

## Responsibility boundaries

- The iOS client owns the user identity, sender signature checks, message content, and transport choice.
- The relay authenticates receive sessions, queues opaque encrypted envelopes, and notifies recipients. Send sockets omit authenticated sender identity; network metadata remains visible.
- Firmware relays radio/BLE payloads and handles configuration addressed to the node. Meshtastic's public channel key is a transport setting, not the message confidentiality boundary.

## Decisions and tradeoffs

**Native iOS stack.** Apple frameworks cover persistence, Bluetooth, encryption, and UI without third-party app dependencies. The handwritten protobuf codec keeps the app small but makes malformed-input tests essential. It rejects oversized integers, impossible lengths, invalid tags, and incomplete varints.

**Multiple transport paths.** Direct Bluetooth, relayed Bluetooth, internet delivery, and radio nodes have different limits. Routing code chooses a path; it cannot promise background availability, range, or eventual delivery in every topology.

**Bounded incomplete work.** Untrusted fragment headers must not decide how much memory a phone or node retains. The client limits pending transfers and chunk sizes; firmware uses fixed slots and validates indexes, totals, and lengths before writes.

**Authentication before effects.** Incoming sender signatures and stored key bindings are checked before acknowledging accepted messages. Failed key storage rejects the message. Delivery acknowledgments do not themselves produce another acknowledgment.

**Experimental privacy model.** Signatures and encrypted envelopes protect content under the documented trust assumptions. First-contact trust, compromised recipient keys, visible routing metadata, and node administration are separate limitations. See [SECURITY.md](../SECURITY.md).

## What is verified

The readiness review ran 53 iOS tests, 38 relay tests, sanitized firmware parser tests, all four firmware builds, dependency checks, and full-history secret scans. Current CI is the source of truth for the latest commit. Simulator tests need local signing for Keychain access, but no paid developer membership.

No independent cryptographic audit, radio-range benchmark, or fresh hardware interoperability run is implied. Use [the device validation checklist](device-validation.md) before publishing a demo or distributing a firmware build.
