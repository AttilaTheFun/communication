#if canImport(LiveKitWebRTC)
import Foundation

import Communication

/// A small lock-protected wrapper around `AsyncStream` used by delegate callbacks.
final class AsyncPipe<Element: Sendable>: @unchecked Sendable {
    /// Protects access to the stream continuation, which may be touched from WebRTC callbacks.
    private let lock = NSLock()

    /// The continuation used to yield and finish stream values.
    private var continuation: AsyncStream<Element>.Continuation?

    /// The stream consumed by package actors and public API surfaces.
    let stream: AsyncStream<Element>

    /// Creates a pipe that keeps only the most recent events when readers lag.
    init() {
        var continuation: AsyncStream<Element>.Continuation?
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(100)) { streamContinuation in
            continuation = streamContinuation
        }
        self.continuation = continuation
    }

    /// Emits a value into the stream if it is still active.
    func yield(_ event: Element) {
        _ = lock.withLock {
            continuation?.yield(event)
        }
    }

    /// Finishes the stream and releases the continuation.
    func finish() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}
#endif
