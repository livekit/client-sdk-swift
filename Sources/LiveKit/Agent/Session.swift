/*
 * Copyright 2026 LiveKit
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Combine
import Foundation
import OrderedCollections

/// A ``Session`` represents a connection to a LiveKit Room that can contain an ``Agent``.
///
/// ``Session`` is the main entry point for interacting with a LiveKit agent. It encapsulates
/// the connection to a LiveKit ``Room``, manages the agent's lifecycle, and handles
/// communication between the user and the agent.
///
/// ``Session`` is created with a token source and optional configuration. The ``start()``
/// method establishes the connection, and the ``end()`` method terminates it. The session's
/// state, including connection status and any errors, is published for observation,
/// making it suitable for use in SwiftUI applications.
///
/// Communication with the agent is handled through messages. The ``send(text:)`` method
/// sends a user message, and the ``messages`` property provides an ordered history of the
/// conversation. The session can be configured with custom message senders and receivers
/// to support different communication channels, such as text messages or transcription streams.
///
/// - SeeAlso: [LiveKit SwiftUI Agent Starter](https://github.com/livekit-examples/agent-starter-swift).
/// - SeeAlso: [LiveKit Agents documentation](https://docs.livekit.io/agents/).
@MainActor
open class Session: ObservableObject {
    private static let agentNameAttribute = "lk.agent_name"

    // MARK: - Error

    public enum Error: LocalizedError {
        case connection(Swift.Error)
        case sender(Swift.Error)
        case receiver(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case let .connection(error):
                "Connection failed: \(error.localizedDescription)"
            case let .sender(error):
                "Message sender failed: \(error.localizedDescription)"
            case let .receiver(error):
                "Message receiver failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Published

    /// The last error that occurred.
    @Published public private(set) var error: Error?

    /// The current connection state of the session.
    @Published private var connectionState: ConnectionState = .disconnected
    /// A boolean value indicating whether the session is connected.
    public var isConnected: Bool {
        switch connectionState {
        case .connecting, .connected, .reconnecting: // pre-connect is connecting
            true
        default:
            false
        }
    }

    /// The ``Agent`` associated with this session.
    @Published public private(set) var agent = Agent()

    @Published private var messagesDict: OrderedDictionary<ReceivedMessage.ID, ReceivedMessage> = [:]
    /// The ordered list of received messages.
    public var messages: [ReceivedMessage] { messagesDict.values.elements }

    // MARK: - Dependencies

    /// The underlying ``Room`` object for the session.
    public let room: Room

    private enum TokenSourceConfiguration {
        case fixed(any TokenSourceFixed)
        case configurable(any TokenSourceConfigurable, TokenRequestOptions)

        func fetch() async throws -> TokenSourceResponse {
            switch self {
            case let .fixed(source):
                try await source.fetch()
            case let .configurable(source, options):
                try await source.fetch(options)
            }
        }
    }

    private let tokenSourceConfiguration: TokenSourceConfiguration
    private var options: SessionOptions

    private let senders: [any MessageSender]
    private let receivers: [any MessageReceiver]

    // MARK: - Internal state

    private var tasks = Set<AnyTaskCancellable>()
    private var waitForAgentTask: AnyTaskCancellable?

    // MARK: - Init

    private init(tokenSourceConfiguration: TokenSourceConfiguration,
                 options: SessionOptions,
                 senders: [any MessageSender]?,
                 receivers: [any MessageReceiver]?)
    {
        self.tokenSourceConfiguration = tokenSourceConfiguration
        self.options = options
        room = options.room

        let textMessageSender = TextMessageSender(room: room)
        let resolvedSenders = senders ?? [textMessageSender]
        let resolvedReceivers = receivers ?? [textMessageSender, TranscriptionStreamReceiver(room: room)]

        self.senders = resolvedSenders
        self.receivers = resolvedReceivers

        observe(room: room)
        observe(receivers: resolvedReceivers)
    }

    /// Initializes a new ``Session`` with a fixed token source.
    /// - Parameters:
    ///   - tokenSource: A token source that provides a fixed token.
    ///   - options: The session options.
    ///   - senders: An array of message senders.
    ///   - receivers: An array of message receivers.
    public convenience init(tokenSource: any TokenSourceFixed,
                            options: SessionOptions = .init(),
                            senders: [any MessageSender]? = nil,
                            receivers: [any MessageReceiver]? = nil)
    {
        self.init(tokenSourceConfiguration: .fixed(tokenSource),
                  options: options,
                  senders: senders,
                  receivers: receivers)
    }

    /// Initializes a new ``Session`` with a configurable token source.
    /// - Parameters:
    ///   - tokenSource: A token source that can generate tokens with specific options.
    ///   - tokenOptions: The options for generating the token.
    ///   - options: The session options.
    ///   - senders: An array of message senders.
    ///   - receivers: An array of message receivers.
    public convenience init(tokenSource: any TokenSourceConfigurable,
                            tokenOptions: TokenRequestOptions = .init(),
                            options: SessionOptions = .init(),
                            senders: [any MessageSender]? = nil,
                            receivers: [any MessageReceiver]? = nil)
    {
        self.init(tokenSourceConfiguration: .configurable(tokenSource, tokenOptions),
                  options: options,
                  senders: senders,
                  receivers: receivers)
    }

    /// Creates a new ``Session`` configured for a specific agent.
    /// - Parameters:
    ///   - agentName: The name of the agent to dispatch.
    ///   - agentMetadata: Metadata passed to the agent.
    ///   - tokenSource: A configurable token source.
    ///   - options: The session options.
    ///   - senders: An array of message senders.
    ///   - receivers: An array of message receivers.
    /// - Returns: A new ``Session`` instance.
    public static func withAgent(_ agentName: String,
                                 agentMetadata: String? = nil,
                                 tokenSource: any TokenSourceConfigurable,
                                 options: SessionOptions = .init(),
                                 senders: [any MessageSender]? = nil,
                                 receivers: [any MessageReceiver]? = nil) -> Session
    {
        Session(tokenSource: tokenSource,
                tokenOptions: .init(agentName: agentName, agentMetadata: agentMetadata),
                options: options,
                senders: senders,
                receivers: receivers)
    }

    private func observe(room: Room) {
        room.changes.subscribeOnMainActor(self) { observer, _ in
            observer.updateAgent(in: room)
        }.store(in: &tasks)
    }

    private func updateAgent(in room: Room) {
        connectionState = room.connectionState

        if connectionState == .disconnected {
            agent.disconnected()
        } else if let firstAgent = room.agentParticipants.values.first {
            agent.connected(participant: firstAgent)
        } else if agent.isConnected {
            agent.failed(error: .left)
        } else {
            agent.connecting(buffering: options.preConnectAudio)
        }
    }

    private func observe(receivers: [any MessageReceiver]) {
        let (stream, continuation) = AsyncStream.makeStream(of: ReceivedMessage.self)

        // Multiple producers → single stream
        for receiver in receivers {
            Task { [weak self] in
                do {
                    for await message in try await receiver.messages() {
                        continuation.yield(message)
                    }
                } catch {
                    self?.error = .receiver(error)
                }
            }.cancellable().store(in: &tasks)
        }

        // Single consumer
        stream.subscribeOnMainActor(self) { observer, message in
            observer.messagesDict.updateValue(message, forKey: message.id)
        }.store(in: &tasks)
    }

    // MARK: - Lifecycle

    /// Starts the session.
    public func start() async {
        guard connectionState == .disconnected else { return }

        error = nil
        waitForAgentTask = nil

        let timeout = options.agentConnectTimeout

        let connect = { @Sendable in
            let response = try await self.tokenSourceConfiguration.fetch()
            try await self.room.connect(url: response.serverURL.absoluteString,
                                        token: response.participantToken)
            return response.dispatchesAgent()
        }

        do {
            let dispatchesAgent: Bool
            if options.preConnectAudio {
                dispatchesAgent = try await room.withPreConnectAudio(timeout: timeout) {
                    await MainActor.run {
                        self.connectionState = .connecting
                        self.agent.connecting(buffering: true)
                    }
                    return try await connect()
                }
            } else {
                connectionState = .connecting
                agent.connecting(buffering: false)
                dispatchesAgent = try await connect()
                try await room.localParticipant.setMicrophone(enabled: true)
            }

            if dispatchesAgent {
                waitForAgentTask = Task { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(timeout * Double(NSEC_PER_SEC)))
                    try Task.checkCancellation()
                    guard let self else { return }
                    if isConnected, !agent.isConnected {
                        agent.failed(error: .timeout)
                    }
                }.cancellable()
            }
        } catch {
            self.error = .connection(error)
            connectionState = .disconnected
            agent.disconnected()
        }
    }

    /// Terminates the session.
    public func end() async {
        await room.disconnect()
    }

    /// Resets the last error.
    public func dismissError() {
        error = nil
    }

    // MARK: - Messages

    /// Sends a text message.
    /// - Parameter text: The text to send.
    /// - Returns: The ``SentMessage`` that was sent, or `nil` if the message failed to send.
    @discardableResult
    public func send(text: String) async -> SentMessage? {
        let message = SentMessage(id: UUID().uuidString, timestamp: Date(), content: .userInput(text))
        do {
            for sender in senders {
                try await sender.send(message)
            }
            return message
        } catch {
            self.error = .sender(error)
            return nil
        }
    }

    /// Gets the message history.
    /// - Returns: An array of ``ReceivedMessage``.
    public func getMessageHistory() -> [ReceivedMessage] {
        messages
    }

    /// Restores the message history.
    /// - Parameter messages: An array of ``ReceivedMessage`` to restore.
    public func restoreMessageHistory(_ messages: [ReceivedMessage]) {
        messagesDict = .init(uniqueKeysWithValues: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { ($0.id, $0) })
    }
}
