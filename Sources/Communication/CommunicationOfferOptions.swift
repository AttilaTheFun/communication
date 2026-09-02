/// Options used when creating an SDP offer or answer.
public struct CommunicationOfferOptions: Sendable, Equatable {
    /// Whether the generated media constraints should allow receiving audio.
    public var receivesAudio: Bool

    /// Whether the generated media constraints should allow receiving video.
    public var receivesVideo: Bool

    /// Whether offer creation should request an ICE restart.
    public var restartsICE: Bool

    /// Whether WebRTC voice activity detection should be enabled.
    public var usesVoiceActivityDetection: Bool

    /// Creates offer or answer options.
    ///
    /// - Parameters:
    ///   - receivesAudio: Whether the peer should offer or answer with audio reception.
    ///   - receivesVideo: Whether the peer should offer or answer with video reception.
    ///   - restartsICE: Whether this negotiation should restart ICE.
    ///   - usesVoiceActivityDetection: Whether WebRTC voice activity detection is enabled.
    public init(
        receivesAudio: Bool = true,
        receivesVideo: Bool = false,
        restartsICE: Bool = false,
        usesVoiceActivityDetection: Bool = true
    ) {
        self.receivesAudio = receivesAudio
        self.receivesVideo = receivesVideo
        self.restartsICE = restartsICE
        self.usesVoiceActivityDetection = usesVoiceActivityDetection
    }
}
