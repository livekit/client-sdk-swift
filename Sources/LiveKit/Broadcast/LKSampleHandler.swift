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

#if os(iOS)

#if canImport(ReplayKit)
import ReplayKit
#endif

import Combine
import OSLog

#if !COCOAPODS
import LKObjCHelpers
#endif

@available(macCatalyst 13.1, *)
open class LKSampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var uploader: BroadcastUploader?
    private var cancellable = Set<AnyCancellable>()

    private lazy var log: OSLog = enableLogging ? OSLog(subsystem: "io.livekit.sdk", category: "LKSampleHandler") : .disabled

    override public init() {
        super.init()
        os_log("LKSampleHandler created", log: log, type: .info)

        createUploader()

        DarwinNotificationCenter.shared
            .publisher(for: .broadcastRequestStop)
            .sink { [weak self] _ in
                os_log("Received stop request", log: self?.log ?? .disabled, type: .info)
                self?.finishBroadcastWithoutError()
            }
            .store(in: &cancellable)
    }

    override public func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.
        os_log("Broadcast started", log: log, type: .info)
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
    }

    override public func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
        os_log("Broadcast paused", log: log, type: .info)
    }

    override public func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
        os_log("Broadcast resumed", log: log, type: .info)
    }

    override public func broadcastFinished() {
        // User has requested to finish the broadcast.
        os_log("Broadcast finished", log: log, type: .info)
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        uploader?.close()
    }

    override public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        do {
            try uploader?.upload(sampleBuffer, with: type)
        } catch {
            guard case .connectionClosed = error as? BroadcastUploader.Error else {
                os_log("Failed to send sample: %{public}@", log: log, type: .error, String(describing: error))
                return
            }
            finishBroadcastWithoutError()
        }
    }

    /// Override point to change the behavior when the socket connection has closed.
    /// The default behavior is to pass errors through, and otherwise show nothing to the user.
    ///
    /// You should call `finishBroadcastWithError` in your implementation, but you can
    /// add custom logging or present a custom error to the user instead.
    ///
    /// To present a custom error message:
    ///   ```
    ///   self.finishBroadcastWithError(NSError(
    ///     domain: RPRecordingErrorDomain,
    ///     code: 10001,
    ///     userInfo: [NSLocalizedDescriptionKey: "My Custom Error Message"]
    ///   ))
    ///   ```
    open func connectionDidClose(error: Error?) {
        if let error {
            finishBroadcastWithError(error)
        } else {
            finishBroadcastWithoutError()
        }
    }

    private func finishBroadcastWithoutError() {
        LKObjCHelpers.finishBroadcastWithoutError(self)
    }

    private func createUploader() {
        guard let socketPath = BroadcastBundleInfo.socketPath else {
            os_log("Bundle settings improperly configured for screen capture", log: log, type: .error)
            return
        }
        Task {
            do {
                uploader = try await BroadcastUploader(socketPath: socketPath)
                os_log("Uploader connected", log: log, type: .info)
            } catch {
                os_log("Uploader connection failed: %{public}@", log: log, type: .error, String(describing: error))
                connectionDidClose(error: error)
            }
        }
    }

    // MARK: - Logging

    /// Whether or not to bootstrap the logging system when initialized.
    ///
    /// Disabled by default. Enable by overriding this property to return true.
    ///
    open var enableLogging: Bool { false }

    /// Whether or not to include debug and trace messages in log output.
    ///
    /// Disabled by default. Enable by overriding this property to return true.
    /// - SeeAlso: ``enableLogging``
    ///
    open var verboseLogging: Bool { false }
}

#endif
