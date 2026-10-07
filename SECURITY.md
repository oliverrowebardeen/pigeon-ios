# Security

Report potential vulnerabilities in the Pigeon iOS client through [GitHub private vulnerability reporting](https://github.com/oliverrowebardeen/pigeon-ios/security/advisories/new). Include the affected commit, reproduction steps, and impact in the private report.

If the reporting form is unavailable, open an issue asking the maintainer to enable private vulnerability reporting. Include no vulnerability details, exploit code, personal information, or credentials in that public request. Wait for a private channel before sending the report.

Security fixes target `main`; there are no supported releases. Reports are handled on a best-effort basis without a guaranteed response time.

Only test devices and relay instances you own or are authorized to test. This is experimental software; the code review and automated tests are not an independent cryptographic audit.

Messages are encrypted in transit, but message history is stored as plaintext in the app's local SwiftData database under iOS platform protections. Sender signing keys use trust on first use; verify contact keys out of band when identity assurance matters. Ephemeral sender keys do not provide forward secrecy against later compromise of a recipient's long-term private key. Relay operators can observe recipient routing hashes, network addresses, timing, and sizes. BLE discovery exposes presence and public identifiers.
