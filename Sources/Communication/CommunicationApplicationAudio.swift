import Foundation

/// Who plays a connection's received audio and captures its microphone.
public enum CommunicationAudioPlayback: String, Sendable, Codable, Equatable {
    /// The backend plays every connection's received audio and captures the
    /// microphone itself, mixed, through the platform's audio device.
    case system
    /// The application does: it pulls each connection's received audio on its
    /// own audio thread (so it can place, mix or spatialize each peer), and
    /// pushes microphone audio in (`CommunicationApplicationAudio`). The
    /// Web Audio shape of `createMediaStreamSource(remoteStream)`.
    case application
}

/// A connection's audio when its configuration asks for
/// `CommunicationAudioPlayback.application`: the audio its peer sends,
/// decoded, pulled at the application's pace, and the microphone audio it
/// sends, pushed by the application. Mono Float32 samples at `sampleRate`.
///
/// Real-time: unlike the rest of the API these calls are synchronous and
/// allocation-free, made from an audio render or capture thread. Call
/// `renderReceived` from one thread and `deliverCaptured` from one thread.
public protocol CommunicationApplicationAudio: AnyObject, Sendable {
    /// Samples per second of both directions (48 000).
    var sampleRate: Double { get }

    /// Fills `frameCount` samples of this connection's received audio into
    /// `buffer`: silence while nothing is being received.
    func renderReceived(into buffer: UnsafeMutablePointer<Float>, frameCount: Int)

    /// Sends `frameCount` microphone samples to this connection's local audio
    /// tracks. Ignored until a track made by `makeMicrophoneTrack()` is added.
    func deliverCaptured(_ buffer: UnsafePointer<Float>, frameCount: Int)

    /// A local audio track fed by `deliverCaptured`, for `addTrack`. Tracks
    /// from `CommunicationMediaDevices` capture through the system instead.
    func makeMicrophoneTrack() throws -> any CommunicationMediaStreamTrack
}
