# Device validation

Record app commit, relay commit, firmware commit, phone models/iOS versions, radio boards, channel/settings, and observed results for a real test. Use synthetic contacts and messages. This checklist is a procedure, not evidence that these tests passed.

1. Two phones: exchange direct messages, replies, reactions, and read receipts over BLE without internet; disconnect/reconnect and confirm recovery.
2. Relay: use an instance you control, exchange messages, disconnect the recipient, reconnect, and verify queued delivery. Confirm delivery acknowledgments stop after receipt.
3. Bridge: disable internet on one phone, route through a connected bridge, and verify transport changes and recovery when the bridge disappears.
4. Radio: verify short-message delivery on the exact Pigeon/Meshtastic hardware and firmware combination. Exercise multi-chunk native LoRa messages and ensure malformed/oversized input is dropped.
5. Identity: verify a contact out of band and confirm a changed signing key is rejected. Check behavior after app restart.
6. Node control: treat BLE provisioning as unauthenticated. Provision only in a trusted environment; secure unattended administration needs a separate pairing design and device validation.
7. Demo: record a short continuous send/receive sequence with the active transport visible. State the observed setup; do not infer measured range or reliability from a successful short run.

The separate local beacon experiment changes periodic traffic from 30-second to 10-second intervals and peer expiry from 90 to 30 seconds. Compare discovery latency, missed-beacon behavior, airtime, and power on hardware before making that the default.
