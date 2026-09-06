import AVFoundation
import Communication
import Foundation
@preconcurrency public import WebRTC

/// One factory for the process, so tracks from the devices and peer
/// connections from the connector belong together, plus the SSL init
/// libwebrtc wants once.
final class WebRTCRuntime: @unchecked Sendable {
    static let shared = WebRTCRuntime()
    private let lock = NSLock()
    private var made: RTCPeerConnectionFactory?
    private var initialized = false

    var factory: RTCPeerConnectionFactory {
        get throws {
            lock.lock(); defer { lock.unlock() }
            if let made { return made }
            if !initialized {
                guard RTCInitializeSSL() else {
                    throw CommunicationError(code: .initializationFailed, message: "Unable to initialize WebRTC SSL.")
                }
                initialized = true
            }
            let factory = RTCPeerConnectionFactory()
            made = factory
            return factory
        }
    }
}

/// `MediaStreamTrack` over an `RTCMediaStreamTrack`. Holds the wrapper
/// strongly: libwebrtc hands out a fresh wrapper per lookup and a released
/// wrapper takes its renderers with it. A local capture track owns its
/// capturer and stops it on `stop()`.
public final class WebRTCMediaTrack: CommunicationMediaStreamTrack, @unchecked Sendable {
    let raw: RTCMediaStreamTrack
    private let lock = NSLock()
    private var capturer: RTCCameraVideoCapturer?
    private var source: RTCAudioSource?
    private var renderers: [RTCVideoRenderer] = []

    init(_ raw: RTCMediaStreamTrack, capturer: RTCCameraVideoCapturer? = nil, source: RTCAudioSource? = nil) {
        self.raw = raw
        self.capturer = capturer
        self.source = source
    }

    public var id: String { raw.trackId }
    public var kind: CommunicationMediaKind { raw.kind == kRTCMediaStreamTrackKindVideo ? .video : .audio }

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
    public func add(renderer: RTCVideoRenderer) {
        lock.lock(); defer { lock.unlock() }
        guard let video = raw as? RTCVideoTrack else { return }
        renderers.append(renderer)
        video.add(renderer)
    }

    public func remove(renderer: RTCVideoRenderer) {
        lock.lock(); defer { lock.unlock() }
        guard let video = raw as? RTCVideoTrack else { return }
        renderers.removeAll { $0 === renderer }
        video.remove(renderer)
    }

    deinit {
        if let video = raw as? RTCVideoTrack { for r in renderers { video.remove(r) } }
        capturer?.stopCapture()
    }
}

public final class WebRTCRtpSender: CommunicationRtpSender, @unchecked Sendable {
    let raw: RTCRtpSender
    init(_ raw: RTCRtpSender) { self.raw = raw }
    public var track: (any CommunicationMediaStreamTrack)? { raw.track.map { WebRTCMediaTrack($0) } }
    public func replaceTrack(_ track: (any CommunicationMediaStreamTrack)?) throws {
        if let track, !(track is WebRTCMediaTrack) { throw CommunicationError(code: .invalidState, message: "track is not from this backend") }
        raw.track = (track as? WebRTCMediaTrack)?.raw
    }
}

public final class WebRTCRtpReceiver: CommunicationRtpReceiver, @unchecked Sendable {
    let raw: RTCRtpReceiver
    init(_ raw: RTCRtpReceiver) { self.raw = raw }
    public var track: (any CommunicationMediaStreamTrack)? { raw.track.map { WebRTCMediaTrack($0) } }
}

public final class WebRTCRtpTransceiver: CommunicationRtpTransceiver, @unchecked Sendable {
    let raw: RTCRtpTransceiver
    init(_ raw: RTCRtpTransceiver) { self.raw = raw }
    public var mid: String? { raw.mid.isEmpty ? nil : raw.mid }
    public var kind: CommunicationMediaKind { raw.mediaType == .video ? .video : .audio }
    public var direction: CommunicationTransceiverDirection { CommunicationTransceiverDirection(raw.direction) }
    public var currentDirection: CommunicationTransceiverDirection? {
        var current = RTCRtpTransceiverDirection.inactive
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
/// audio device module, a camera through `RTCCameraVideoCapturer` at the
/// format nearest 640 pixels wide.
public struct WebRTCMediaDevices: CommunicationMediaDevices {
    private let factory: RTCPeerConnectionFactory

    public init() throws { factory = try WebRTCRuntime.shared.factory }

    public func audioTrack() throws -> any CommunicationMediaStreamTrack {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio-" + UUID().uuidString)
        return WebRTCMediaTrack(track, source: source)
    }

    public func videoTrack(camera position: CommunicationCameraPosition) throws -> any CommunicationMediaStreamTrack {
        let devices = RTCCameraVideoCapturer.captureDevices()
        let wanted: AVCaptureDevice.Position? = position == .front ? .front : position == .back ? .back : nil
        guard let device = devices.first(where: { wanted == nil || $0.position == wanted }) ?? devices.first else {
            throw CommunicationError(code: .initializationFailed, message: "no camera")
        }
        guard let format = RTCCameraVideoCapturer.supportedFormats(for: device).min(by: { a, b in
            abs(Int(CMVideoFormatDescriptionGetDimensions(a.formatDescription).width) - 640)
                < abs(Int(CMVideoFormatDescriptionGetDimensions(b.formatDescription).width) - 640)
        }) else { throw CommunicationError(code: .initializationFailed, message: "no camera format") }
        let fps = Int(min(30, format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "video-" + UUID().uuidString)
        let capturer = RTCCameraVideoCapturer(delegate: source)
        capturer.startCapture(with: device, format: format, fps: fps)
        return WebRTCMediaTrack(track, capturer: capturer)
    }
}

// MARK: Video views

#if canImport(UIKit)
import UIKit
public typealias WebRTCVideoView = RTCMTLVideoView
#else
import AppKit
public typealias WebRTCVideoView = RTCMTLNSVideoView
#endif

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

extension CommunicationTransceiverDirection {
    init(_ direction: RTCRtpTransceiverDirection) {
        switch direction {
        case .sendRecv: self = .sendRecv
        case .sendOnly: self = .sendOnly
        case .recvOnly: self = .recvOnly
        case .inactive: self = .inactive
        case .stopped: self = .stopped
        @unknown default: self = .inactive
        }
    }

    var rtcDirection: RTCRtpTransceiverDirection {
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
    var rtcMediaType: RTCRtpMediaType { self == .video ? .video : .audio }
}
