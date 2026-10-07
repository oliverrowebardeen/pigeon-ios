# Third-party notices

The Pigeon iOS application links Apple SDK frameworks and has no third-party package dependencies or vendored libraries. Apple SDKs and developer tools remain subject to Apple's terms.

## Protocol references

`MeshtasticProtobuf.swift` and `MeshtasticConstants.swift` implement a subset of the [Meshtastic protocol](https://github.com/meshtastic/protobufs) using a handwritten Swift codec. This repository does not bundle Meshtastic firmware, generated protobuf code, or a protobuf runtime. The upstream Meshtastic definitions have their own [GPL-3.0 license](https://github.com/meshtastic/protobufs/blob/master/LICENSE); Pigeon's MIT license does not relicense upstream material. Meshtastic is a separate project, and this integration does not imply its endorsement.

## Community documentation

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) is a shortened adaptation of [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/), created by the Contributor Covenant project, under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Its attribution and license apply separately from Pigeon's MIT software license.

When introducing a dependency, generated source, or copied asset, include its applicable license and attribution in the same change.
