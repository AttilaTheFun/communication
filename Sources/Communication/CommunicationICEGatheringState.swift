/// The ICE candidate gathering state for a peer connection.
public enum CommunicationICEGatheringState: String, Sendable, CaseIterable {
    /// ICE gathering has not started.
    case fresh

    /// ICE gathering is in progress.
    case gathering

    /// ICE gathering completed.
    case complete

    /// WebRTC reported a state unknown to this wrapper.
    case unknown
}
