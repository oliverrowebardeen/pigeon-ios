# Security

Report potential vulnerabilities in the Pigeon iOS client privately to **security@example.com**, the existing Pigeon project security contact. Include the affected commit, reproduction steps, and impact. Do not put credentials, private keys, or exploitable details into public issues.

Only test devices and relay instances you own or are authorized to test. This is experimental software; the code review and automated tests are not an independent cryptographic audit.

Messages are encrypted in transit, but message history is stored as plaintext in the app's local SwiftData database under iOS platform protections. Sender signing keys use trust on first use; verify contact keys out of band when identity assurance matters. Ephemeral sender keys do not provide forward secrecy against later compromise of a recipient's long-term private key. Relay operators can observe recipient routing hashes, network addresses, timing, and sizes. BLE discovery exposes presence and public identifiers.
