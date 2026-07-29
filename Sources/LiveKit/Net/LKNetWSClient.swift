// Copyright 2026 LiveKit (Apache-2.0)
import Foundation
internal import LiveKitUniFFI

/// Live WebSocket transport backing `livekit-net`, over `URLSessionWebSocketTask`.
final class LKNetWSClientLive: WsClient, @unchecked Sendable {
    func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
        guard let u = URL(string: url) else { throw TransportError.Connection("invalid url: \(url)") }
        let conn = try await LKNetWSConnection(url: u, headers: headers, timeoutMs: timeoutMs)
        return WsConnectResult(connection: conn)
    }
}

/// Forwarding WS client registered with `livekit-net`. Production forwards to
/// `LKNetWSClientLive`; `#if DEBUG` tests swap the delegate to a dummy.
final class LKNetWSClient: WsClient, @unchecked Sendable {
    private let delegate: StateSync<any WsClient>

    init(_ initial: any WsClient = LKNetWSClientLive()) {
        delegate = StateSync(initial)
    }

    #if DEBUG
    func setDelegate(_ d: any WsClient) { delegate.mutate { $0 = d } }
    #endif

    func connect(url: String, headers: [Header], timeoutMs: UInt64) async throws -> WsConnectResult {
        try await delegate.read { $0 }.connect(url: url, headers: headers, timeoutMs: timeoutMs)
    }
}

/// One open WebSocket for `livekit-net`. Binary frames only; string frames are
/// decoded as UTF-8 bytes at the boundary (Swift does not interpret content).
final class LKNetWSConnection: WsConnection, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let connectDelegate: WSConnectDelegate

    init(url: URL, headers: [Header], timeoutMs: UInt64) async throws {
        var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy,
                             timeoutInterval: TimeInterval(timeoutMs) / 1000.0)
        for h in headers { req.addValue(h.value, forHTTPHeaderField: h.name) }

        connectDelegate = WSConnectDelegate()
        session = URLSession(configuration: .default, delegate: connectDelegate, delegateQueue: nil)
        task = session.webSocketTask(with: req)

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connectDelegate.setConnectContinuation(cont)
                task.resume()
            }
        } catch {
            session.invalidateAndCancel()
            throw Self.map(error)
        }
    }

    deinit {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    func send(frame: Data) async throws {
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.send(.data(frame)) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        } catch {
            throw Self.map(error)
        }
    }

    func recv() async throws -> Data? {
        guard task.closeCode == .invalid else { return nil }
        do {
            let message: URLSessionWebSocketTask.Message = try await withCheckedThrowingContinuation { cont in
                task.receive { cont.resume(with: $0) }
            }
            return Self.decode(message)
        } catch {
            if task.closeCode != .invalid { return nil }
            throw Self.map(error)
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    static func decode(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case let .data(d): return d
        case let .string(s): return Data(s.utf8)
        @unknown default: return Data()
        }
    }

    private static func map(_ error: Error) -> TransportError {
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .Timeout
            case .cancelled: return .Closed
            default: return .Connection(u.localizedDescription)
            }
        }
        return .Connection("\(error)")
    }
}

/// Bridges `URLSessionWebSocketDelegate` open/close callbacks to a continuation.
/// Mirrors `Support/Network/WebSocket.swift`'s `Delegate`.
private final class WSConnectDelegate: NSObject, URLSessionWebSocketDelegate {
    private let continuation = StateSync<CheckedContinuation<Void, Error>?>(nil)

    func setConnectContinuation(_ c: CheckedContinuation<Void, Error>) {
        continuation.mutate { $0 = c }
    }

    func urlSession(_: URLSession, webSocketTask _: URLSessionWebSocketTask, didOpenWithProtocol _: String?) {
        continuation.mutate { $0?.resume(); $0 = nil }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        continuation.mutate {
            if let error { $0?.resume(throwing: error) } else { $0?.resume() }
            $0 = nil
        }
    }
}
