/// The SHA-256 of each LiveKit libwebrtc download the tool takes, by
/// release and platform: a release or platform not here is refused, and a
/// download that doesn't match is refused. Add a release by its assets'
/// digests on GitHub (`gh api repos/livekit/rust-sdks/releases/tags/<tag>
/// --jq '.assets[] | .name + " " + .digest'`), checked against a download.
enum Pins {
    static let sha256: [String: [Platform: String]] = [
        "webrtc-83af826": [
            .linuxX64: "dd607db1d307a0e4bbba63ad02d4cd5e25ecc85bcb3c669a9ba1b54c7474de39",
            .linuxArm64: "c24aedd492f60662e181d3f869ab7fc5f14a3edd9fd2110ed2da3873e42eb6d6",
            .androidArm64: "8f5897ec262c93da5880f74a9e4fd8cc9af850f0c1031009560787f121c48f5d",
            .androidX64: "6202a54704c402a98a9c062b755fad70e35a403e9b2cc794c68d5c2206759128",
        ],
    ]
}
