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

#if os(iOS)

#if canImport(ReplayKit)
import ReplayKit
#endif

#if swift(>=5.9)
internal import Logging
#else
@_implementationOnly import Logging
#endif

import LKObjCHelpers
import OSLog

@available(macCatalyst 13.1, *)
open class LKSampleHandler: RPBroadcastSampleHandler {
    private var clientConnection: BroadcastUploadSocketConnection?
    private var uploader: SampleUploader?

    override public init() {
        super.init()
        bootstrapLogging()
        logger.info("LKSampleHandler created")

        let socketPath = BroadcastScreenCapturer.socketPath
        if socketPath == nil {
            logger.error("Bundle settings improperly configured for screen capture")
        }
        if let connection = BroadcastUploadSocketConnection(filePath: socketPath ?? "") {
            clientConnection = connection
            setupConnection()

            uploader = SampleUploader(connection: connection)
        }
    }

    override public func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.
        logger.info("Broadcast started")
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        openConnection()
    }

    override public func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
        logger.info("Broadcast paused")
    }

    override public func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
        logger.info("Broadcast resumed")
    }

    override public func broadcastFinished() {
        // User has requested to finish the broadcast.
        logger.info("Broadcast finished")
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        clientConnection?.close()
    }

    override public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case RPSampleBufferType.video:
            uploader?.send(sample: sampleBuffer)
        default:
            break
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
            LKObjCHelpers.finishBroadcastWithoutError(self)
        }
    }

    private func setupConnection() {
        clientConnection?.didClose = { [weak self] error in
            logger.log(level: .debug, "client connection did close \(String(describing: error))")
            guard let self else {
                return
            }

            self.connectionDidClose(error: error)
        }
    }

    private func openConnection() {
        let queue = DispatchQueue(label: "broadcast.connectTimer")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard self?.clientConnection?.open() == true else {
                return
            }

            timer.cancel()
        }

        timer.resume()
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

    private func bootstrapLogging() {
        guard enableLogging else { return }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let logger = OSLog(subsystem: bundleIdentifier, category: "LKSampleHandler")
        let logLevel = verboseLogging ? Logger.Level.trace : .info

        LoggingSystem.bootstrap { _ in
            var logHandler = OSLogHandler(logger)
            logHandler.logLevel = logLevel
            return logHandler
        }
    }
}

#endif
