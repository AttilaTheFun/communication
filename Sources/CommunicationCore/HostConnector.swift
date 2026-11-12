import Communication

/// Makes peer connections over a `WebRTCHost`: the connector on every
/// platform whose WebRTC comes through a host (the web, Android, Linux and
/// Windows; and Apple, once its backend is an adapter).
public struct HostConnector: CommunicationConnector {
    public let host: any WebRTCHost

    public init(host: any WebRTCHost) {
        self.host = host
    }

    public func makePeerConnection(configuration: CommunicationConfiguration) throws -> any CommunicationPeerConnection {
        let connection = HostPeerConnection(host: host, configuration: configuration)
        // Events start flowing as soon as the host has the connection,
        // whether or not the caller has called anything yet.
        Task { await connection.startPump() }
        return connection
    }

    public func makeMediaDevices() throws -> any CommunicationMediaDevices {
        throw HostPeerConnection.noMedia
    }
}
