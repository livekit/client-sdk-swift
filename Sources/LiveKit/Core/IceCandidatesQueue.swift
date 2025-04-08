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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

/// Queue for handling ICE candidates with timestamp-based ordering
actor IceCandidatesQueue: Loggable {
    // MARK: - Types

    enum State: Sendable {
        case resumed
        case suspended
    }

    /// Timestamped ice candidate to ensure proper ordering
    struct TimestampedIceCandidate: Sendable, Comparable {
        let candidate: IceCandidate
        let timestamp: Date

        // Add Comparable conformance for more efficient sorting
        static func < (lhs: TimestampedIceCandidate, rhs: TimestampedIceCandidate) -> Bool {
            lhs.timestamp < rhs.timestamp
        }

        // Add Equatable conformance since IceCandidate doesn't conform to Equatable
        static func == (lhs: TimestampedIceCandidate, rhs: TimestampedIceCandidate) -> Bool {
            // Compare by timestamp since that's what we use for ordering
            lhs.timestamp == rhs.timestamp
        }
    }

    // MARK: - Properties

    private var queue = [TimestampedIceCandidate]()
    private var state: State = .suspended
    private let peerConnection: LKRTCPeerConnection
    // Track if we're currently processing candidates to avoid concurrent operations
    private var isProcessing = false

    // MARK: - Lifecycle

    init(peerConnection: LKRTCPeerConnection) {
        self.peerConnection = peerConnection
    }

    // MARK: - Public methods

    /// Process a candidate if the specified condition is true, otherwise queue it
    func process(_ candidate: IceCandidate, if condition: Bool) async {
        let timestampedCandidate = TimestampedIceCandidate(
            candidate: candidate,
            timestamp: Date()
        )

        if condition, state == .resumed, !isProcessing {
            try? await addToPeerConnection(timestampedCandidate.candidate)
        } else {
            queue.append(timestampedCandidate)
        }
    }

    /// Mark queue as resumed and process all queued candidates
    func resume() async {
        // If already processing, just update state and return
        guard !isProcessing else {
            state = .resumed
            return
        }

        state = .resumed
        await processQueuedCandidates()
    }

    /// Process all queued candidates
    private func processQueuedCandidates() async {
        guard !queue.isEmpty, !isProcessing else { return }

        isProcessing = true
        defer { isProcessing = false }

        // Create a local copy and clear queue
        let candidatesToProcess = queue.sorted()
        queue.removeAll()

        // Process in correct timestamp order
        for timestampedCandidate in candidatesToProcess {
            if state == .suspended {
                // If suspended during processing, put remaining candidates back in queue
                queue.append(contentsOf: candidatesToProcess.filter { $0.timestamp >= timestampedCandidate.timestamp })
                break
            }
            try? await addToPeerConnection(timestampedCandidate.candidate)
        }
    }

    /// Clear all queued candidates and mark as suspended
    func clear() {
        if !queue.isEmpty {
            log("Clearing queue with \(queue.count) candidates", .warning)
        }

        queue.removeAll()
        state = .suspended
    }

    /// Mark as suspended
    func suspend() {
        state = .suspended
    }

    /// Get current queue count
    var count: Int { queue.count }

    // MARK: - Private methods

    private func addToPeerConnection(_ candidate: IceCandidate) async throws {
        do {
            try await peerConnection.add(candidate.toRTCType())
        } catch {
            log("Failed to add ICE candidate with error: \(error)", .error)
            throw error
        }
    }
}
