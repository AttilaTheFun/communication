#if arch(wasm32)
import CCommunicationWeb
import Communication
import CommunicationCore
import Foundation

/// The web's `WebRTCHost`: the browser's own `RTCPeerConnection`, through
/// the `communication_webrtc` wasm imports, which
/// `Web/communication_webrtc.js` implements (`Docs/platforms.md`). Give it
/// to `HostConnector` to run the shared implementation over the browser's
/// WebRTC.
///
/// The page passes the imports to whatever instantiates the wasm, and runs
/// Swift's concurrency on the browser's event loop (as Isomer and
/// JavaScriptKit do): results and events arrive from the JavaScript as
/// calls into the module's exports, which resume the awaiting tasks.
///
/// The host speaks W3C already, so the JSON passes straight through.
public final class WebWebRTCHost: WebRTCHost, @unchecked Sendable {
    // `@unchecked`: everything below is guarded by `lock` (wasm has one
    // thread, but the type doesn't say so).
    private let lock = NSLock()
    private var connections: [Int32: WebConnection] = [:]

    public init() {
        WebBridge.install()
    }

    public func create(configuration: String) async throws -> Int32 {
        let id = Self.withBytes(configuration) { cw_web_create($0, $1) }
        guard id >= 0 else {
            throw CommunicationError(code: .initializationFailed, message: "The browser couldn't create an RTCPeerConnection.")
        }
        let connection = WebConnection()
        lock.withLock { connections[id] = connection }
        WebBridge.adopt(id, connection)
        return id
    }

    public func createOffer(connection id: Int32, options: String) async throws -> String {
        try await WebBridge.result { token in Self.withBytes(options) { cw_web_offer(id, 0, $0, $1, token) } }
    }

    public func createAnswer(connection id: Int32, options: String) async throws -> String {
        try await WebBridge.result { token in Self.withBytes(options) { cw_web_offer(id, 1, $0, $1, token) } }
    }

    public func setLocalDescription(connection id: Int32, description: String) async throws {
        _ = try await WebBridge.result { token in
            Self.withBytes(description) { cw_web_set_description(id, 1, $0, $1, token) }
        }
    }

    public func setRemoteDescription(connection id: Int32, description: String) async throws {
        _ = try await WebBridge.result { token in
            Self.withBytes(description) { cw_web_set_description(id, 0, $0, $1, token) }
        }
    }

    public func localDescription(connection id: Int32) async -> String {
        (try? await WebBridge.result { token in cw_web_local_description(id, token) }) ?? ""
    }

    public func addCandidate(connection id: Int32, candidate: String) async throws {
        _ = try await WebBridge.result { token in
            Self.withBytes(candidate) { cw_web_add_candidate(id, $0, $1, token) }
        }
    }

    public func restartICE(connection id: Int32) async {
        cw_web_restart_ice(id)
    }

    public func openDataChannel(connection id: Int32, label: String, configuration: String) async throws {
        let opened = Self.withBytes(label) { labelBytes, labelLength in
            Self.withBytes(configuration) { cw_web_open_channel(id, labelBytes, labelLength, $0, $1) }
        }
        guard opened == 0 else {
            throw CommunicationError(code: .initializationFailed, message: "Could not open data channel \(label).")
        }
    }

    public func sendText(connection id: Int32, channel: String, text: String) async throws {
        try send(id, channel, Array(text.utf8), binary: false)
    }

    public func sendData(connection id: Int32, channel: String, data: [UInt8]) async throws {
        try send(id, channel, data, binary: true)
    }

    public func nextEvent(connection id: Int32) async throws -> WebRTCHostEvent {
        guard let connection = lock.withLock({ connections[id] }) else { return WebRTCHostEvent(.closed) }
        return try await connection.events.next()
    }

    public func disconnect(connection id: Int32) async {
        lock.withLock { _ = connections.removeValue(forKey: id) }
        cw_web_close(id)
    }

    private func send(_ id: Int32, _ label: String, _ bytes: [UInt8], binary: Bool) throws {
        let sent = Self.withBytes(label) { labelBytes, labelLength in
            bytes.withUnsafeBufferPointer { cw_web_send(id, labelBytes, labelLength, $0.baseAddress, $0.count, binary ? 1 : 0) }
        }
        guard sent == 0 else {
            throw CommunicationError(code: .invalidState, message: "Could not send on data channel \(label).")
        }
    }

    /// A string's UTF-8, its pointer and length, for one call.
    static func withBytes<T>(_ string: String, _ body: (UnsafePointer<CChar>?, Int) -> T) -> T {
        var copy = string
        return copy.withUTF8 { buffer in
            buffer.withMemoryRebound(to: CChar.self) { body($0.baseAddress, $0.count) }
        }
    }
}

/// A connection's events, queued as the JavaScript reports them.
private final class WebConnection: @unchecked Sendable {
    let events = WebEventQueue()
}

/// The exports' side: tokens for operations in flight, and each
/// connection's queue, which the C trampolines reach through the handlers
/// installed here.
private final class WebBridge: @unchecked Sendable {
    // `@unchecked`: everything below is guarded by `lock`.
    static let shared = WebBridge()
    private let lock = NSLock()
    private var pending: [Int32: CheckedContinuation<String, any Error>] = [:]
    private var queues: [Int32: WebEventQueue] = [:]
    private var nextToken: Int32 = 1
    private var installed = false

    static func install() {
        let first = shared.lock.withLock {
            defer { shared.installed = true }
            return !shared.installed
        }
        if first { cw_web_set_handlers(onEvent, onResult) }
    }

    static func adopt(_ id: Int32, _ connection: WebConnection) {
        shared.lock.withLock { shared.queues[id] = connection.events }
    }

    /// Runs a call that ends with a result for its token, and gives its
    /// JSON ("" for a call that makes none).
    static func result(_ call: (Int32) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let token = shared.lock.withLock {
                let token = shared.nextToken
                shared.nextToken = token == Int32.max ? 1 : token + 1
                shared.pending[token] = continuation
                return token
            }
            call(token)
        }
    }

    private static let onResult: cw_web_result_fn = { token, ok, text, length in
        let continuation = shared.lock.withLock { shared.pending.removeValue(forKey: token) }
        let string = text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: length), as: UTF8.self) } ?? ""
        if ok != 0 {
            continuation?.resume(returning: string)
        } else {
            continuation?.resume(throwing: CommunicationError(code: .webRTCOperationFailed, message: string))
        }
    }

    private static let onEvent: cw_web_event_fn = { id, kind, channel, channelLength, text, textLength, data, dataLength in
        let closing = kind == WebRTCHostEvent.Kind.closed.rawValue
        let queue = shared.lock.withLock { closing ? shared.queues.removeValue(forKey: id) : shared.queues[id] }
        func string(_ pointer: UnsafePointer<CChar>?, _ length: Int) -> String {
            pointer.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: length), as: UTF8.self) } ?? ""
        }
        let bytes = data.map { [UInt8](UnsafeBufferPointer(start: $0, count: dataLength)) } ?? []
        queue?.post(WebRTCHostEvent(kind: kind, channel: string(channel, channelLength),
                                    text: string(text, textLength), data: bytes))
    }
}

/// Events queued until the core pulls them, as the native host's.
private final class WebEventQueue: @unchecked Sendable {
    // `@unchecked`: everything below is guarded by `lock`.
    private let lock = NSLock()
    private var queue: [WebRTCHostEvent] = []
    private var waiting: [UUID: CheckedContinuation<WebRTCHostEvent?, Never>] = [:]
    private var order: [UUID] = []
    private var closed = false

    /// The next event, or `.closed` once the connection is gone; a pull
    /// that's cancelled throws `CancellationError`.
    func next() async throws -> WebRTCHostEvent {
        let id = UUID()
        let event: WebRTCHostEvent? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WebRTCHostEvent?, Never>) in
                let ready: WebRTCHostEvent?? = lock.withLock {
                    if !queue.isEmpty { return .some(queue.removeFirst()) }
                    if closed { return .some(WebRTCHostEvent(.closed)) }
                    if Task.isCancelled { return .some(nil) }
                    waiting[id] = continuation
                    order.append(id)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiter = lock.withLock {
                order.removeAll { $0 == id }
                return waiting.removeValue(forKey: id)
            }
            waiter?.resume(returning: nil)
        }
        guard let event else { throw CancellationError() }
        return event
    }

    func post(_ event: WebRTCHostEvent) {
        if event.kind == WebRTCHostEvent.Kind.closed.rawValue {
            let waiters: [CheckedContinuation<WebRTCHostEvent?, Never>] = lock.withLock {
                closed = true
                defer {
                    waiting.removeAll()
                    order.removeAll()
                }
                return order.compactMap { waiting[$0] }
            }
            for waiter in waiters { waiter.resume(returning: event) }
            return
        }
        let waiter: CheckedContinuation<WebRTCHostEvent?, Never>? = lock.withLock {
            guard !closed else { return nil }
            guard let first = order.first else {
                queue.append(event)
                return nil
            }
            order.removeFirst()
            return waiting.removeValue(forKey: first)
        }
        waiter?.resume(returning: event)
    }
}
#endif
