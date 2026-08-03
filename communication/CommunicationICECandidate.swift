@preconcurrency internal import WebRTC

/// A WebRTC ICE candidate represented as Swift value data.
public struct CommunicationICECandidate: Sendable, Codable, Equatable, Hashable {
    /// The SDP candidate attribute.
    public var sdp: String

    /// The zero-based media line index for the candidate.
    public var sdpMLineIndex: Int32

    /// The optional media stream identification value for the candidate.
    public var sdpMid: String?

    /// The optional ICE server URL that produced the candidate.
    public var serverURL: String?

    /// Creates an ICE candidate value.
    ///
    /// - Parameters:
    ///   - sdp: The SDP candidate attribute.
    ///   - sdpMLineIndex: The zero-based media line index.
    ///   - sdpMid: The optional media stream identification value.
    ///   - serverURL: The optional ICE server URL that produced the candidate.
    public init(
        sdp: String,
        sdpMLineIndex: Int32,
        sdpMid: String? = nil,
        serverURL: String? = nil
    ) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
        self.serverURL = serverURL
    }
}

/// Conversion between Swift ICE candidates and WebRTC ICE candidates.
extension CommunicationICECandidate {
    /// Creates a Swift candidate from a WebRTC candidate.
    init(_ candidate: RTCIceCandidate) {
        self.init(
            sdp: candidate.sdp,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid,
            serverURL: candidate.serverUrl
        )
    }

    /// The raw WebRTC candidate represented by this value.
    var rtcIceCandidate: RTCIceCandidate {
        RTCIceCandidate(
            sdp: sdp,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid
        )
    }
}
