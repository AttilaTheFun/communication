@preconcurrency internal import WebRTC

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

/// Conversion from Swift offer/answer options to WebRTC media constraints.
extension CommunicationOfferOptions {
    /// The raw WebRTC media constraints used while creating offers and answers.
    var rtcConstraints: RTCMediaConstraints {
        RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: receivesAudio.rtcConstraintValue,
                kRTCMediaConstraintsOfferToReceiveVideo: receivesVideo.rtcConstraintValue,
                kRTCMediaConstraintsIceRestart: restartsICE.rtcConstraintValue,
                kRTCMediaConstraintsVoiceActivityDetection: usesVoiceActivityDetection.rtcConstraintValue,
            ],
            optionalConstraints: nil
        )
    }
}

/// WebRTC media constraint conversion helpers.
private extension Bool {
    /// The string constant WebRTC expects for boolean media constraints.
    var rtcConstraintValue: String {
        self ? kRTCMediaConstraintsValueTrue : kRTCMediaConstraintsValueFalse
    }
}
