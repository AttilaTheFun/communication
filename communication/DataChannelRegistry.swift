import Foundation

@preconcurrency internal import WebRTC

/// Owns the data channels on a peer connection and turns their callbacks into
/// `CommunicationEvent` values.
///
/// Both sides of a connection see channels the same way: the side that calls
/// `open` gets one immediately, and the side that does not gets the same
/// channel through `didOpen` when the remote creates it. Either way the
/// channel ends up here under its label, so `send(_:on:)` behaves identically
/// on both — which is what lets a caller write one code path instead of two.
final class DataChannelRegistry: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: RTCDataChannel] = [:]
    private let emit: @Sendable (CommunicationEvent) -> Void

    init(emit: @escaping @Sendable (CommunicationEvent) -> Void) {
        self.emit = emit
    }

    /// Adopts a channel — created locally or handed over by the remote.
    func adopt(_ channel: RTCDataChannel) {
        lock.lock()
        channels[channel.label] = channel
        lock.unlock()
        channel.delegate = self
        if channel.readyState == .open {
            // A channel can already be open by the time we see it; the
            // state-change callback will not fire retroactively.
            emit(.dataChannelOpened(label: channel.label))
        }
    }

    func channel(labeled label: String) -> RTCDataChannel? {
        lock.lock(); defer { lock.unlock() }
        return channels[label]
    }

    /// The single open channel, when there is exactly one — the common case
    /// for an application that opens a channel and never thinks about it again.
    func soleOpenChannel() -> RTCDataChannel? {
        lock.lock(); defer { lock.unlock() }
        let open = channels.values.filter { $0.readyState == .open }
        return open.count == 1 ? open.first : nil
    }

    func closeAll() {
        lock.lock()
        let all = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        for channel in all { channel.close() }
    }

    // MARK: - RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        emit(.dataChannelStateChanged(
            label: dataChannel.label,
            state: CommunicationDataChannelState(dataChannel.readyState)
        ))
        if dataChannel.readyState == .open {
            emit(.dataChannelOpened(label: dataChannel.label))
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        // `isBinary` is the sender's declaration, and it is preserved rather
        // than guessed at: text that happens to be valid UTF-8 bytes is not
        // the same thing as text.
        let message: CommunicationDataChannelMessage =
            buffer.isBinary
                ? .binary(buffer.data)
                : .text(String(decoding: buffer.data, as: UTF8.self))
        emit(.dataChannelMessage(label: dataChannel.label, message: message))
    }
}

extension CommunicationDataChannelState {
    init(_ state: RTCDataChannelState) {
        switch state {
        case .connecting: self = .connecting
        case .open: self = .open
        case .closing: self = .closing
        case .closed: self = .closed
        @unknown default: self = .closed
        }
    }
}

extension CommunicationDataChannelConfiguration {
    var rtcConfiguration: RTCDataChannelConfiguration {
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = ordered
        if let maxRetransmitTimeMilliseconds {
            configuration.maxRetransmitTimeMs = maxRetransmitTimeMilliseconds
        }
        if let maxRetransmits {
            configuration.maxRetransmits = Int32(maxRetransmits)
        }
        if let channelID {
            configuration.isNegotiated = true
            configuration.channelId = channelID
        }
        return configuration
    }
}
