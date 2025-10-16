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

import Foundation
import OrderedCollections

@MainActor
open class Conversation: ObservableObject {
    // MARK: - Error

    public enum Error: LocalizedError {
        case agentNotConnected
        case failedToConnect(Swift.Error)
        case failedToSend(Swift.Error)

        public var errorDescription: String? {
            "TODO"
        }
    }

    // MARK: - State

    @Published public private(set) var error: Error?

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isListening = false
    public var isReady: Bool {
        switch connectionState {
        case .disconnected where isListening,
             .connecting where isListening,
             .connected,
             .reconnecting:
            true
        default:
            false
        }
    }

    @Published public private(set) var agents: [Participant.Identity: Agent] = [:]
    public var hasAgents: Bool { !agents.isEmpty }

    @Published public private(set) var messages: OrderedDictionary<ReceivedMessage.ID, ReceivedMessage> = [:]

    // MARK: - Dependencies

    public let room: Room

    private enum AnyTokenSource {
        case fixed(any TokenSourceFixed)
        case configurable(any TokenSourceConfigurable)
    }

    private let tokenSource: AnyTokenSource
    private let agentName: String?

    private let senders: [any MessageSender]
    private let receivers: [any MessageReceiver]

    // MARK: - Internal state

    private var waitForAgentTask: Task<Void, Swift.Error>?

    // MARK: - Init

    private init(tokenSource: AnyTokenSource,
                 agentName: String?,
                 room: Room,
                 senders: [any MessageSender]?,
                 receivers: [any MessageReceiver]?)
    {
        self.tokenSource = tokenSource
        self.agentName = agentName
        self.room = room

        let textMessageSender = TextMessageSender(room: room)
        let senders = senders ?? [textMessageSender]
        let receivers = receivers ?? [textMessageSender, TranscriptionStreamReceiver(room: room)]

        self.senders = senders
        self.receivers = receivers

        observe(room: room, agentName: agentName)
        observe(receivers: receivers)
    }

    public convenience init(tokenSource: some TokenSourceFixed,
                            room: Room = .init(),
                            senders: [any MessageSender]? = nil,
                            receivers: [any MessageReceiver]? = nil)
    {
        self.init(tokenSource: .fixed(tokenSource), agentName: nil, room: room, senders: senders, receivers: receivers)
    }

    public convenience init(tokenSource: some TokenSourceConfigurable,
                            room: Room = .init(),
                            agentName: String? = nil,
                            senders: [any MessageSender]? = nil,
                            receivers: [any MessageReceiver]? = nil)
    {
        self.init(tokenSource: .configurable(tokenSource), agentName: agentName, room: room, senders: senders, receivers: receivers)
    }

    private func observe(room: Room, agentName _: String?) {
        Task { [weak self] in
            for try await _ in room.changes {
                guard let self else { return }

                connectionState = room.connectionState
                updateAgents(in: room)
            }
        }
    }

    private func updateAgents(in room: Room) {
        let agentParticipants = room.agentParticipants

        var newAgents: [Participant.Identity: Agent] = [:]

        for (identity, participant) in agentParticipants {
            if let existingAgent = agents[identity] {
                newAgents[identity] = existingAgent
            } else {
                let newAgent = Agent(participant: participant)
                newAgents[identity] = newAgent
            }
        }

        agents = newAgents
    }

    private func observe(receivers: [any MessageReceiver]) {
        for receiver in receivers {
            Task { [weak self] in
                for await message in try await receiver.messages() {
                    guard let self else { return }
                    messages.updateValue(message, forKey: message.id)
                }
            }
        }
    }

    // MARK: - Agents

    public func agent(named name: String) -> Agent? {
        agents.values.first { $0.participant.attributes["lk.agent_name"] == name || $0.participant.identity?.stringValue == name }
    }

    public subscript(name: String) -> Agent? {
        agent(named: name)
    }

    // MARK: - Lifecycle

    public func start(preConnectAudio: Bool = true, waitForAgent: TimeInterval = 20, options: ConnectOptions? = nil, roomOptions: RoomOptions? = nil) async {
        guard connectionState == .disconnected else { return }

        error = nil
        waitForAgentTask?.cancel()

        defer {
            waitForAgentTask = Task {
                try await Task.sleep(nanoseconds: UInt64(TimeInterval(NSEC_PER_SEC) * waitForAgent))
                try Task.checkCancellation()
                if connectionState == .connected, agents.isEmpty {
                    await end()
                    self.error = .agentNotConnected
                }
            }
        }

        do {
            let response: TokenSourceResponse = switch tokenSource {
            case let .fixed(s):
                try await s.fetch()
            case let .configurable(s):
                try await s.fetch(TokenRequestOptions(agentName: agentName))
            }

            if preConnectAudio {
                try await room.withPreConnectAudio(timeout: waitForAgent) {
                    await MainActor.run { self.isListening = true }
                    try await self.room.connect(url: response.serverURL.absoluteString,
                                                token: response.participantToken,
                                                connectOptions: options,
                                                roomOptions: roomOptions)
                    await MainActor.run { self.isListening = false }
                }
            } else {
                try await room.connect(url: response.serverURL.absoluteString,
                                       token: response.participantToken,
                                       connectOptions: options,
                                       roomOptions: roomOptions)
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
        messages.values.elements
    }

    public func restoreMessageHistory(_ messages: [ReceivedMessage]) {
        self.messages = .init(uniqueKeysWithValues: messages.sorted(by: { $0.timestamp < $1.timestamp }).map { ($0.id, $0) })
    }
}
