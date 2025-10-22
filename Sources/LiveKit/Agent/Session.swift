/*
 * Copyright 2025 LiveKit
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

@MainActor
open class Session: ObservableObject {
    private static let agentNameAttribute = "lk.agent_name"

    // MARK: - Error

    public enum Error: LocalizedError {
        case failedToConnect(Swift.Error)
        case failedToSend(Swift.Error)

        public var errorDescription: String? {
            switch self {
            case let .failedToConnect(error):
                "Failed to connect: \(error.localizedDescription)"
            case let .failedToSend(error):
                "Failed to send: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - State

    @Published public private(set) var error: Error?

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    public var isConnected: Bool {
        switch connectionState {
        case .connecting, .connected:
            true
        default:
            false
        }
    }

    @Published public private(set) var agent = Agent()

    @Published private var messagesDict: OrderedDictionary<ReceivedMessage.ID, ReceivedMessage> = [:]
    public var messages: [ReceivedMessage] { messagesDict.values.elements }

    // MARK: - Dependencies

    public let room: Room

    private enum TokenSourceConfiguration {
        case fixed(any TokenSourceFixed)
        case configurable(any TokenSourceConfigurable, TokenRequestOptions)
    }

    private let tokenSourceConfiguration: TokenSourceConfiguration
    private var options: SessionOptions

    private let senders: [any MessageSender]
    private let receivers: [any MessageReceiver]

    // MARK: - Internal state

    private var waitForAgentTask: Task<Void, Swift.Error>?

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

    deinit {
        waitForAgentTask?.cancel()
    }

    private func observe(room: Room) {
        Task { [weak self] in
            for try await _ in room.changes {
                guard let self else { return }

                connectionState = room.connectionState
                agent = updatedAgent(in: room)
            }
        }
    }

    private func updatedAgent(in room: Room) -> Agent {
        var agent = Agent()

        if connectionState != .disconnected {
            agent = .connecting()
        }

        if let firstAgent = room.agentParticipants.values.first {
            agent = .connected(participant: firstAgent)
        }

        return agent
    }

    private func observe(receivers: [any MessageReceiver]) {
        for receiver in receivers {
            Task { [weak self] in
                for await message in try await receiver.messages() {
                    guard let self else { return }
                    messagesDict.updateValue(message, forKey: message.id)
                }
            }
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard connectionState == .disconnected else { return }

        error = nil
        waitForAgentTask?.cancel()

        let timeout = options.agentConnectTimeout

        defer {
            waitForAgentTask = Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * Double(NSEC_PER_SEC)))
                try Task.checkCancellation()
                guard let self else { return }
                if isConnected, !agent.isConnected {
                    self.agent = .failed(.timeout)
                }
            }
        }

        do {
            let response = try await fetchToken()

            if options.preConnectAudio {
                try await room.withPreConnectAudio(timeout: timeout) {
                    await MainActor.run { self.agent = .listening() }
                    try await self.room.connect(url: response.serverURL.absoluteString,
                                                token: response.participantToken)
                }
            } else {
                try await room.connect(url: response.serverURL.absoluteString,
                                       token: response.participantToken)
            }
        } catch {
            self.error = .failedToConnect(error)
        }
    }

    public func end() async {
        await room.disconnect()
    }

    public func resetError() {
        error = nil
    }

    // MARK: - Messages

    @discardableResult
    public func send(text: String) async -> SentMessage {
        let message = SentMessage(id: UUID().uuidString, timestamp: Date(), content: .userInput(text))
        do {
            for sender in senders {
                try await sender.send(message)
            }
        } catch {
            self.error = .failedToSend(error)
        }
        return message
    }

    public func getMessageHistory() -> [ReceivedMessage] {
        messages
    }

    public func restoreMessageHistory(_ messages: [ReceivedMessage]) {
        messagesDict = .init(uniqueKeysWithValues: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { ($0.id, $0) })
    }

    // MARK: - Helpers

    private func fetchToken() async throws -> TokenSourceResponse {
        switch tokenSourceConfiguration {
        case let .fixed(source):
            try await source.fetch()
        case let .configurable(source, options):
            try await source.fetch(options)
        }
    }
}
