import Foundation

/// The media half of the WebRTC API, as the W3C spec shapes it:
/// `MediaStreamTrack`, `RTCRtpSender`, `RTCRtpReceiver`, `RTCRtpTransceiver`,
/// and `navigator.mediaDevices.getUserMedia` (Media Capture and Streams).
/// Reference types, like the spec's objects; every property is safe to
/// read from any task and mutations go through the backend's own lock.

public enum CommunicationMediaKind: String, Sendable, Codable, Equatable {
    case audio
    case video
}

/// `RTCRtpTransceiverDirection`.
public enum CommunicationTransceiverDirection: String, Sendable, Codable, Equatable {
    case sendRecv = "sendrecv"
    case sendOnly = "sendonly"
    case recvOnly = "recvonly"
    case inactive
    case stopped
}

/// `MediaStreamTrack`: a source of audio or video, local (from a device)
/// or remote (from a receiver). `isEnabled` is `enabled`; a disabled track
/// sends silence or black frames. `stop` ends a local capture for good.
public protocol CommunicationMediaStreamTrack: AnyObject, Sendable {
    var id: String { get }
    var kind: CommunicationMediaKind { get }
    var isEnabled: Bool { get set }
    func stop()
}

/// `RTCRtpSender`.
public protocol CommunicationRtpSender: AnyObject, Sendable {
    var track: (any CommunicationMediaStreamTrack)? { get }
    func replaceTrack(_ track: (any CommunicationMediaStreamTrack)?) async throws
}

/// `RTCRtpReceiver`.
public protocol CommunicationRtpReceiver: AnyObject, Sendable {
    var track: (any CommunicationMediaStreamTrack)? { get }
}

/// `RTCRtpTransceiver`.
public protocol CommunicationRtpTransceiver: AnyObject, Sendable {
    var mid: String? { get }
    var kind: CommunicationMediaKind { get }
    var direction: CommunicationTransceiverDirection { get }
    /// The negotiated direction, once there is one.
    var currentDirection: CommunicationTransceiverDirection? { get }
    var sender: any CommunicationRtpSender { get }
    var receiver: any CommunicationRtpReceiver { get }
    var isStopped: Bool { get }
    func setDirection(_ direction: CommunicationTransceiverDirection) throws
    func stop()
}

public enum CommunicationCameraPosition: String, Sendable, Codable, Equatable {
    case front
    case back
    case any
}

/// `getUserMedia`, one track at a time: the microphone, or a camera.
/// Tracks come from the same factory as the peer connections, so they can
/// be added to any connection the connector makes.
public protocol CommunicationMediaDevices: Sendable {
    func audioTrack() throws -> any CommunicationMediaStreamTrack
    func videoTrack(camera: CommunicationCameraPosition) throws -> any CommunicationMediaStreamTrack
}
