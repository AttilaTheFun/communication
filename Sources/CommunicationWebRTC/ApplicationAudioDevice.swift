import AudioToolbox
import Communication
import Foundation
import os

@preconcurrency internal import LiveKitWebRTC

/// `CommunicationAudioPlayback.application` on Apple platforms: a custom
/// libwebrtc audio device, one per connection (each connection then has a
/// factory of its own), so the playout it hands back is that connection's
/// peer alone. Nothing here opens an audio unit: the application's audio
/// engine drives both directions through `renderReceived` and
/// `deliverCaptured`, and libwebrtc's fine audio buffers take any frame
/// count. Samples cross the boundary as mono 16-bit at 48 kHz, as the device
/// declares.
final class ApplicationAudioDevice: NSObject, LKRTCAudioDevice, CommunicationApplicationAudio, @unchecked Sendable {
    let sampleRate: Double = 48_000
    /// The most frames one call converts; larger requests go in slices.
    private static let chunk = 4_096

    private struct State {
        var delegate: (any LKRTCAudioDeviceDelegate)?
        var initialized = false
        var playoutInitialized = false
        var playing = false
        var recordingInitialized = false
        var recording = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Scratch for the render and capture threads, allocated once.
    private let playout = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    private let capture = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
    private var playoutTime = AudioTimeStamp()
    private var captureTime = AudioTimeStamp()

    /// The connection's factory, for microphone tracks; set once it exists.
    weak var factory: LKRTCPeerConnectionFactory?

    override init() {
        super.init()
        playoutTime.mFlags = .sampleTimeValid
        captureTime.mFlags = .sampleTimeValid
    }

    deinit {
        playout.deallocate()
        capture.deallocate()
    }

    // MARK: CommunicationApplicationAudio

    func renderReceived(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        let (delegate, playing) = state.withLock { ($0.delegate, $0.playing) }
        guard let delegate, playing else {
            buffer.update(repeating: 0, count: frameCount)
            return
        }
        var done = 0
        while done < frameCount {
            let n = min(Self.chunk, frameCount - done)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(n * 2), mData: UnsafeMutableRawPointer(playout)))
            var flags = AudioUnitRenderActionFlags()
            let status = delegate.getPlayoutData(&flags, &playoutTime, 0, UInt32(n), &list)
            playoutTime.mSampleTime += Double(n)
            if status == noErr {
                for i in 0..<n { buffer[done + i] = Float(playout[i]) / 32_768 }
            } else {
                (buffer + done).update(repeating: 0, count: n)
            }
            done += n
        }
    }

    func deliverCaptured(_ buffer: UnsafePointer<Float>, frameCount: Int) {
        let (delegate, recording) = state.withLock { ($0.delegate, $0.recording) }
        guard let delegate, recording else { return }
        var done = 0
        while done < frameCount {
            let n = min(Self.chunk, frameCount - done)
            for i in 0..<n { capture[i] = Int16(max(-1, min(1, buffer[done + i])) * 32_767) }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(n * 2), mData: UnsafeMutableRawPointer(capture)))
            var flags = AudioUnitRenderActionFlags()
            _ = delegate.deliverRecordedData(&flags, &captureTime, 1, UInt32(n), &list, nil, nil)
            captureTime.mSampleTime += Double(n)
            done += n
        }
    }

    func makeMicrophoneTrack() throws -> any CommunicationMediaStreamTrack {
        guard let factory else {
            throw CommunicationError(code: .invalidState, message: "the connection's audio factory is gone")
        }
        let source = factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "audio-" + UUID().uuidString)
        return WebRTCMediaTrack(track, source: source)
    }

    // MARK: LKRTCAudioDevice

    var deviceInputSampleRate: Double { sampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { sampleRate }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { state.withLock { $0.initialized } }
    var isPlayoutInitialized: Bool { state.withLock { $0.playoutInitialized } }
    var isPlaying: Bool { state.withLock { $0.playing } }
    var isRecordingInitialized: Bool { state.withLock { $0.recordingInitialized } }
    var isRecording: Bool { state.withLock { $0.recording } }

    func initialize(with delegate: any LKRTCAudioDeviceDelegate) -> Bool {
        state.withLock { $0.delegate = delegate; $0.initialized = true }
        return true
    }

    func terminateDevice() -> Bool {
        state.withLock { $0 = State() }
        return true
    }

    func initializePlayout() -> Bool { state.withLock { $0.playoutInitialized = true }; return true }
    func startPlayout() -> Bool { state.withLock { $0.playing = true }; return true }
    func stopPlayout() -> Bool { state.withLock { $0.playing = false }; return true }
    func initializeRecording() -> Bool { state.withLock { $0.recordingInitialized = true }; return true }
    func startRecording() -> Bool { state.withLock { $0.recording = true }; return true }
    func stopRecording() -> Bool { state.withLock { $0.recording = false }; return true }
}
