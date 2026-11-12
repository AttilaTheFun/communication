#if canImport(LiveKitWebRTC)
import AVFoundation
import Communication
import os

/// Plays connections made with `CommunicationAudioPlayback.application`
/// through one `AVAudioEngine`, each peer a mono source in an
/// `AVAudioEnvironmentNode` (HRTF) at a position the application sets,
/// and, when enabled, feeds the microphone to all of them with voice
/// processing (echo cancellation), so peers do not hear themselves.
/// `start(captureMicrophone: false)` listens only; the microphone can be
/// turned on later with `setMicrophoneEnabled(true)`, which is also the
/// only point permission is asked for.
///
/// ```swift
/// let audio = WebRTCSpatialAudio()
/// try await audio.start(captureMicrophone: false)        // listen only
/// try await audio.setMicrophoneEnabled(true)             // on the user's opt-in
/// let source = audio.add(peer.applicationAudio!)       // after makePeerConnection
/// _ = try await peer.addTrack(try peer.applicationAudio!.makeMicrophoneTrack(), streamIDs: ["voice"])
/// source.position = AVAudio3DPoint(x: 1, y: 0, z: -2)   // on each pose update
/// audio.listenerPosition = …                            // the local head
/// ```
@MainActor
public final class WebRTCSpatialAudio {
    public let engine = AVAudioEngine()
    public let environment = AVAudioEnvironmentNode()
    private let format: AVAudioFormat
    private var sources: [ObjectIdentifier: AVAudioSourceNode] = [:]
    /// The connections the microphone feeds; read on the capture thread.
    private let listeners = OSAllocatedUnfairLock(initialState: [any CommunicationApplicationAudio]())

    public init(sampleRate: Double = 48_000) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(environment)
        environment.renderingAlgorithm = .HRTFHQ
        environment.distanceAttenuationParameters.referenceDistance = 1
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
    }

    /// The listener, in the environment's metres.
    public var listenerPosition: AVAudio3DPoint {
        get { environment.listenerPosition }
        set { environment.listenerPosition = newValue }
    }

    public var listenerAngularOrientation: AVAudio3DAngularOrientation {
        get { environment.listenerAngularOrientation }
        set { environment.listenerAngularOrientation = newValue }
    }

    /// Whether the microphone is captured and fed to the connections.
    public private(set) var isMicrophoneEnabled = false

    /// Starts playback. With `captureMicrophone` false it only listens: the
    /// input is never touched, so nothing asks for microphone permission,
    /// and `setMicrophoneEnabled(true)` can turn capture on later. With true
    /// it asks for permission first and throws if it is refused.
    public func start(captureMicrophone: Bool = true) async throws {
        if captureMicrophone { try await Self.requestMicrophonePermission() }
        try configureSession(recording: captureMicrophone)
        if captureMicrophone { try installMicrophone() }
        try engine.start()
    }

    /// Turns microphone capture on or off while playing. Turning it on asks
    /// for permission (only then) and throws if refused; either way the
    /// engine restarts briefly, and every peer's source, position and the
    /// listener stay as they were.
    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard enabled != isMicrophoneEnabled else { return }
        if enabled { try await Self.requestMicrophonePermission() }
        let wasRunning = engine.isRunning
        engine.stop()
        if enabled {
            try configureSession(recording: true)
            try installMicrophone()
        } else {
            removeMicrophone()
            try configureSession(recording: false)
        }
        if wasRunning { try engine.start() }
    }

    public func stop() {
        removeMicrophone()
        engine.stop()
    }

    private func configureSession(recording: Bool) throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        if recording {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try session.setActive(true)
        #endif
    }

    /// Voice processing (echo cancellation) on the input, and a tap that
    /// converts to 48 kHz mono and feeds every added connection.
    private func installMicrophone() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let hardware = input.outputFormat(forBus: 0)
        let target = format
        let converter = AVAudioConverter(from: hardware, to: target)
        let listeners = listeners
        input.installTap(onBus: 0, bufferSize: 480, format: hardware) { buffer, _ in
            guard let converter else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / hardware.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let samples = out.floatChannelData?[0], out.frameLength > 0 else { return }
            for audio in listeners.withLock({ $0 }) { audio.deliverCaptured(samples, frameCount: Int(out.frameLength)) }
        }
        isMicrophoneEnabled = true
    }

    private func removeMicrophone() {
        guard isMicrophoneEnabled else { return }
        engine.inputNode.removeTap(onBus: 0)
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isMicrophoneEnabled = false
    }

    private static func requestMicrophonePermission() async throws {
        #if os(iOS) || os(visionOS)
        let granted = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { done.resume(returning: $0) }
        }
        #else
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard granted else {
            throw CommunicationError(code: .initializationFailed, message: "microphone permission was refused")
        }
    }

    /// Adds a connection: its received audio becomes a positional mono source
    /// (returned; set its `position`, `reverbBlend`, `volume`), and the
    /// microphone starts feeding it.
    @discardableResult
    public func add(_ audio: any CommunicationApplicationAudio) -> AVAudioSourceNode {
        let key = ObjectIdentifier(audio)
        if let existing = sources[key] { return existing }
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let data = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            audio.renderReceived(into: data, frameCount: Int(frameCount))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: environment, format: format)
        node.renderingAlgorithm = .HRTFHQ
        sources[key] = node
        listeners.withLock { $0.append(audio) }
        return node
    }

    /// Removes a connection's source and stops feeding it the microphone.
    public func remove(_ audio: any CommunicationApplicationAudio) {
        let key = ObjectIdentifier(audio)
        listeners.withLock { $0.removeAll { ObjectIdentifier($0) == key } }
        guard let node = sources.removeValue(forKey: key) else { return }
        engine.disconnectNodeOutput(node)
        engine.detach(node)
    }
}
#endif
