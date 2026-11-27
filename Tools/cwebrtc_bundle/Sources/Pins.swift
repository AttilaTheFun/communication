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
        ],
    ]
}
