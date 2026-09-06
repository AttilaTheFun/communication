import Communication
import CommunicationWebRTC
import Foundation

// Two peer connections in one process, negotiated by hand, exchanging one
// text over a data channel. What the package does, in the fewest lines.
@main
struct DataChannelEcho {
    static func main() async throws {
        let connector = WebRTCConnector()
        let a = try connector.makePeerConnection(configuration: CommunicationConfiguration())
        let b = try connector.makePeerConnection(configuration: CommunicationConfiguration())

        // Candidates cross over as they are found.
        Task { for await event in a.events { if case .localCandidateDiscovered(let c) = event { try? await b.addRemoteCandidate(c) } } }
        let received = Task { () -> String in
            for await event in b.events {
                if case .dataChannelMessage(_, let message) = event, case .text(let text) = message { return text }
                if case .localCandidateDiscovered(let c) = event { try? await a.addRemoteCandidate(c) }
            }
            return ""
        }

        try await a.openDataChannel(label: "echo")
        let offer = try await a.offer()
        try await a.setLocalDescription(offer)
        try await b.setRemoteDescription(offer)
        let answer = try await b.answer()
        try await b.setLocalDescription(answer)
        try await a.setRemoteDescription(answer)

        // Wait for the channel, then send.
        for await event in a.events {
            if case .dataChannelStateChanged(_, let state) = event, state == .open { break }
        }
        try await a.send(text: "hello over a data channel")
        print("b received:", await received.value)
        await a.close(); await b.close()
    }
}
