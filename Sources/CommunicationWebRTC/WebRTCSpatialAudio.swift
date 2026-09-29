import AVFoundation
import Communication
import os

/// Plays connections made with `CommunicationAudioPlayback.application`
/// through one `AVAudioEngine`, each peer a mono source in an
/// `AVAudioEnvironmentNode` (HRTF) at a position the application sets,
/// and feeds the microphone to all of them. Voice processing (echo
/// cancellation) is on, so peers do not hear themselves.
///
/// ```swift
/// let audio = WebRTCSpatialAudio()
/// try audio.start()
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
    private var converter: AVAudioConverter?

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

    /// Starts the engine and the microphone. On iOS and visionOS it sets the
    /// shared audio session to voice chat first.
    public func start() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let hardware = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hardware, to: format)
        let listeners = listeners
        let target = format
        let converter = converter
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
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
