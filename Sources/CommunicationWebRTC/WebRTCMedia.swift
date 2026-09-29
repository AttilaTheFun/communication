import AVFoundation
import Communication
import Foundation
@preconcurrency public import LiveKitWebRTC

/// One factory for the process, so tracks from the devices and peer
/// connections from the connector belong together, plus the SSL init
/// libwebrtc wants once.
final class WebRTCRuntime: @unchecked Sendable {
    static let shared = WebRTCRuntime()
    private let lock = NSLock()
    private var made: LKRTCPeerConnectionFactory?
    private var initialized = false

    var factory: LKRTCPeerConnectionFactory {
        get throws {
            lock.lock(); defer { lock.unlock() }
            if let made { return made }
            try initializeSSL()
            let factory = LKRTCPeerConnectionFactory()
            made = factory
            return factory
        }
    }

    /// A factory of its own around an application audio device.
    func makeFactory(audioDevice: any LKRTCAudioDevice) throws -> LKRTCPeerConnectionFactory {
        lock.lock(); defer { lock.unlock() }
        try initializeSSL()
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                          decoderFactory: LKRTCDefaultVideoDecoderFactory(),
                                          audioDevice: audioDevice)
    }

    /// Called with `lock` held.
    private func initializeSSL() throws {
        guard !initialized else { return }
        guard LKRTCInitializeSSL() else {
            throw CommunicationError(code: .initializationFailed, message: "Unable to initialize WebRTC SSL.")
        }
        initialized = true
    }
}

/// `MediaStreamTrack` over an `LKRTCMediaStreamTrack`. Holds the wrapper
/// strongly: libwebrtc hands out a fresh wrapper per lookup and a released
/// wrapper takes its renderers with it. A local capture track owns its
/// capturer and stops it on `stop()`.
public final class WebRTCMediaTrack: CommunicationMediaStreamTrack, @unchecked Sendable {
    let raw: LKRTCMediaStreamTrack
    private let lock = NSLock()
    private var capturer: LKRTCCameraVideoCapturer?
    private var source: LKRTCAudioSource?
    private var renderers: [LKRTCVideoRenderer] = []

    init(_ raw: LKRTCMediaStreamTrack, capturer: LKRTCCameraVideoCapturer? = nil, source: LKRTCAudioSource? = nil) {
        self.raw = raw
        self.capturer = capturer
        self.source = source
    }

    public var id: String { raw.trackId }
    public var kind: CommunicationMediaKind { raw.kind == kLKRTCMediaStreamTrackKindVideo ? .video : .audio }

    public var isEnabled: Bool {
        get { raw.isEnabled }
        set { raw.isEnabled = newValue }
    }

    /// Source volume of a local audio track (`0...1`), a libwebrtc extra.
    public func setGain(_ gain: Float) {
        lock.lock(); defer { lock.unlock() }
        source?.volume = Double(min(max(gain, 0), 1)) * 10
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        capturer?.stopCapture()
        capturer = nil
        raw.isEnabled = false
    }

    // MARK: Rendering (video tracks)

    /// Attaches a renderer; the track keeps it attached for its lifetime.
    public func add(renderer: LKRTCVideoRenderer) {
        lock.lock(); defer { lock.unlock() }
        guard let video = raw as? LKRTCVideoTrack else { return }
        renderers.append(renderer)
        video.add(renderer)
    }

    public func remove(renderer: LKRTCVideoRenderer) {
        lock.lock(); defer { lock.unlock() }
        guard let video = raw as? LKRTCVideoTrack else { return }
        renderers.removeAll { $0 === renderer }
        video.remove(renderer)
    }

    deinit {
        if let video = raw as? LKRTCVideoTrack { for r in renderers { video.remove(r) } }
        capturer?.stopCapture()
    }
}

public final class WebRTCRtpSender: CommunicationRtpSender, @unchecked Sendable {
    let raw: LKRTCRtpSender
    init(_ raw: LKRTCRtpSender) { self.raw = raw }
    public var track: (any CommunicationMediaStreamTrack)? { raw.track.map { WebRTCMediaTrack($0) } }
    public func replaceTrack(_ track: (any CommunicationMediaStreamTrack)?) throws {
        if let track, !(track is WebRTCMediaTrack) { throw CommunicationError(code: .invalidState, message: "track is not from this backend") }
        raw.track = (track as? WebRTCMediaTrack)?.raw
    }
}

public final class WebRTCRtpReceiver: CommunicationRtpReceiver, @unchecked Sendable {
    let raw: LKRTCRtpReceiver
    init(_ raw: LKRTCRtpReceiver) { self.raw = raw }
    public var track: (any CommunicationMediaStreamTrack)? { raw.track.map { WebRTCMediaTrack($0) } }
}

public final class WebRTCRtpTransceiver: CommunicationRtpTransceiver, @unchecked Sendable {
    let raw: LKRTCRtpTransceiver
    init(_ raw: LKRTCRtpTransceiver) { self.raw = raw }
    public var mid: String? { raw.mid.isEmpty ? nil : raw.mid }
    public var kind: CommunicationMediaKind { raw.mediaType == .video ? .video : .audio }
    public var direction: CommunicationTransceiverDirection { CommunicationTransceiverDirection(raw.direction) }
    public var currentDirection: CommunicationTransceiverDirection? {
        var current = LKRTCRtpTransceiverDirection.inactive
        return raw.currentDirection(&current) ? CommunicationTransceiverDirection(current) : nil
    }
    public var sender: any CommunicationRtpSender { WebRTCRtpSender(raw.sender) }
    public var receiver: any CommunicationRtpReceiver { WebRTCRtpReceiver(raw.receiver) }
    public var isStopped: Bool { raw.isStopped }
    public func setDirection(_ direction: CommunicationTransceiverDirection) throws {
        var error: NSError?
        raw.setDirection(direction.rtcDirection, error: &error)
        if let error { throw CommunicationError(code: .invalidState, message: error.localizedDescription) }
    }
    public func stop() { raw.stopInternal() }
}

/// `getUserMedia` on Apple platforms: the microphone through libwebrtc's
/// audio device module, a camera through `LKRTCCameraVideoCapturer` at the
/// format nearest 640 pixels wide.
public struct WebRTCMediaDevices: CommunicationMediaDevices {
    private let factory: LKRTCPeerConnectionFactory

    public init() throws { factory = try WebRTCRuntime.shared.factory }

    public func audioTrack() throws -> any CommunicationMediaStreamTrack {
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio-" + UUID().uuidString)
        return WebRTCMediaTrack(track, source: source)
    }

    public func videoTrack(camera position: CommunicationCameraPosition) throws -> any CommunicationMediaStreamTrack {
        let devices = LKRTCCameraVideoCapturer.captureDevices()
        let wanted: AVCaptureDevice.Position? = position == .front ? .front : position == .back ? .back : nil
        guard let device = devices.first(where: { wanted == nil || $0.position == wanted }) ?? devices.first else {
            throw CommunicationError(code: .initializationFailed, message: "no camera")
        }
        guard let format = LKRTCCameraVideoCapturer.supportedFormats(for: device).min(by: { a, b in
            abs(Int(CMVideoFormatDescriptionGetDimensions(a.formatDescription).width) - 640)
                < abs(Int(CMVideoFormatDescriptionGetDimensions(b.formatDescription).width) - 640)
        }) else { throw CommunicationError(code: .initializationFailed, message: "no camera format") }
        let fps = Int(min(30, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "video-" + UUID().uuidString)
        let capturer = LKRTCCameraVideoCapturer(delegate: source)
        capturer.startCapture(with: device, format: format, fps: fps)
        return WebRTCMediaTrack(track, capturer: capturer)
    }
}

// MARK: Video views

#if os(visionOS)
// LiveKit's visionOS slice has no Metal video view; video on visionOS
// renders through the application (a video renderer of its own).
#elseif canImport(UIKit)
import UIKit
public typealias WebRTCVideoView = LKRTCMTLVideoView
#else
import AppKit
// LiveKit's build has one Metal view for both, an NSView on the Mac.
public typealias WebRTCVideoView = LKRTCMTLVideoView
#endif

#if !os(visionOS)
extension WebRTCVideoView {
    /// A Metal-backed view that renders whichever track it is added to.
    @MainActor
    public static func make() -> WebRTCVideoView {
        let view = WebRTCVideoView(frame: .zero)
        #if canImport(UIKit)
        view.videoContentMode = .scaleAspectFill
        #endif
        return view
    }
}
#endif

extension CommunicationTransceiverDirection {
    init(_ direction: LKRTCRtpTransceiverDirection) {
        switch direction {
        case .sendRecv: self = .sendRecv
        case .sendOnly: self = .sendOnly
        case .recvOnly: self = .recvOnly
        case .inactive: self = .inactive
        case .stopped: self = .stopped
        @unknown default: self = .inactive
        }
    }

    var rtcDirection: LKRTCRtpTransceiverDirection {
        switch self {
        case .sendRecv: .sendRecv
        case .sendOnly: .sendOnly
        case .recvOnly: .recvOnly
        case .inactive: .inactive
        case .stopped: .stopped
        }
    }
}

extension CommunicationMediaKind {
    var rtcMediaType: LKRTCRtpMediaType { self == .video ? .video : .audio }
}
