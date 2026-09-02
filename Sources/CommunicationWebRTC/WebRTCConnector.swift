import Communication

/// The Apple platform's `CommunicationConnector`: peer connections backed by
/// Google's WebRTC.
public struct WebRTCConnector: CommunicationConnector {
    public init() {}

    public func makePeerConnection(
        configuration: CommunicationConfiguration,
        createsLocalAudioTrack: Bool
    ) throws -> any CommunicationPeerConnection {
        try WebRTCPeerConnection(
            configuration: configuration,
            createsLocalAudioTrack: createsLocalAudioTrack
        )
    }
}
