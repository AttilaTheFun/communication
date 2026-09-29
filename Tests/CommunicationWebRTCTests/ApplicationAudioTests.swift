import Communication
import CommunicationWebRTC
import Foundation
import XCTest

/// `CommunicationAudioPlayback.application`: each connection's received
/// audio comes back out of its own `applicationAudio`, and what the
/// application delivers as microphone audio is what the other side receives.
final class ApplicationAudioTests: XCTestCase {
    func testATonePushedOnOneSideIsPulledOnTheOther() async throws {
        let connector = WebRTCConnector()
        let config = CommunicationConfiguration(iceServers: [], audioPlayback: .application)
        let caller = try connector.makePeerConnection(configuration: config)
        let callee = try connector.makePeerConnection(configuration: config)
        defer { Task { await caller.close(); await callee.close() } }
        let sending = try XCTUnwrap(caller.applicationAudio)
        let receiving = try XCTUnwrap(callee.applicationAudio)
        XCTAssertNil(try connector.makePeerConnection().applicationAudio, "system playback has no application audio")

        _ = try await caller.addTrack(try sending.makeMicrophoneTrack(), streamIDs: ["voice"])
        _ = try await callee.addTransceiver(kind: .audio, direction: .recvOnly)

        // Negotiate with complete descriptions (no trickle): host candidates
        // on this machine are enough.
        try await caller.setLocalDescription(try await caller.offer())
        try await Self.gathered(caller)
        let offer = await caller.localDescription
        try await callee.setRemoteDescription(try XCTUnwrap(offer))
        try await callee.setLocalDescription(try await callee.answer())
        try await Self.gathered(callee)
        let answer = await callee.localDescription
        try await caller.setRemoteDescription(try XCTUnwrap(answer))

        // A 440 Hz tone pushed in 10 ms slices in real time, and the other
        // side pulled at the same pace, for up to four seconds.
        let rate = sending.sampleRate
        let slice = Int(rate / 100)
        let tone = UnsafeMutablePointer<Float>.allocate(capacity: slice)
        let heard = UnsafeMutablePointer<Float>.allocate(capacity: slice)
        defer { tone.deallocate(); heard.deallocate() }
        var phase = 0.0
        var loudest: Float = 0
        for _ in 0..<400 {
            for i in 0..<slice {
                tone[i] = Float(sin(phase)) * 0.5
                phase += 2 * .pi * 440 / rate
            }
            sending.deliverCaptured(tone, frameCount: slice)
            receiving.renderReceived(into: heard, frameCount: slice)
            var energy: Float = 0
            for i in 0..<slice { energy += heard[i] * heard[i] }
            loudest = max(loudest, (energy / Float(slice)).squareRoot())
            if loudest > 0.05 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(loudest, 0.05, "the tone should arrive on the other connection's application audio")
    }

    private static func gathered(_ peer: any CommunicationPeerConnection) async throws {
        for _ in 0..<100 {
            if await peer.iceGatheringState == .complete { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
