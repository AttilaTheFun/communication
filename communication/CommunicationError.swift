import Foundation

/// An error produced by the Communication WebRTC wrapper.
public struct CommunicationError: Error, Sendable, Codable, LocalizedError, Equatable {
    /// Stable error categories emitted by the Communication module.
    public enum Code: String, Sendable, Codable {
        /// WebRTC could not be initialized or a peer connection could not be created.
        case initializationFailed

        /// A WebRTC operation failed.
        case webRTCOperationFailed

        /// The requested operation is not supported by the current implementation.
        case unsupportedOperation

        /// The connection is not in a state where this makes sense — sending
        /// on a channel that is not open, most often.
        case invalidState
    }

    /// A stable error code suitable for programmatic handling.
    public var code: Code

    /// A human-readable message suitable for logs and diagnostics.
    public var message: String

    /// Creates a Communication error.
    ///
    /// - Parameters:
    ///   - code: A stable error code.
    ///   - message: A human-readable diagnostic message.
    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    /// The localized error description.
    public var errorDescription: String? {
        message
    }
}
