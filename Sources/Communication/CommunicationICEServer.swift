/// A STUN or TURN server used for ICE gathering.
public struct CommunicationICEServer: Sendable, Codable, Equatable, Hashable {
    /// The ICE server URL strings.
    public var urls: [String]

    /// The optional TURN username.
    public var username: String?

    /// The optional TURN credential.
    public var credential: String?

    /// Creates an ICE server configuration.
    ///
    /// - Parameters:
    ///   - urls: STUN or TURN URLs.
    ///   - username: Optional TURN username.
    ///   - credential: Optional TURN credential.
    public init(
        urls: [String],
        username: String? = nil,
        credential: String? = nil
    ) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    /// Creates a STUN server from a single URL.
    public static func stun(_ url: String) -> Self {
        Self(urls: [url])
    }

    /// Creates a STUN server from one or more URLs.
    public static func stun(_ urls: [String]) -> Self {
        Self(urls: urls)
    }

    /// Creates a TURN server from one or more URLs and credentials.
    public static func turn(
        _ urls: [String],
        username: String,
        credential: String
    ) -> Self {
        Self(
            urls: urls,
            username: username,
            credential: credential
        )
    }
}
