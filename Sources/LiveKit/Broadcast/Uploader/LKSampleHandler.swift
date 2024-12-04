/*
 * Copyright 2024 LiveKit
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

open class LKSampleHandler: RPBroadcastSampleHandler {
    private var clientConnection: BroadcastUploadSocketConnection?
    private var uploader: SampleUploader?

    public var appGroupIdentifier: String? {
        Bundle.main.infoDictionary?[BroadcastScreenCapturer.kAppGroupIdentifierKey] as? String
    }

    public var socketFilePath: String {
        guard let appGroupIdentifier,
              let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else {
            return ""
        }

        return sharedContainer.appendingPathComponent(BroadcastScreenCapturer.kRTCScreensharingSocketFD).path
    }

    override public init() {
        super.init()

        if let connection = BroadcastUploadSocketConnection(filePath: socketFilePath) {
            clientConnection = connection
            setupConnection()

            uploader = SampleUploader(connection: connection)
        }
    }

    override public func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.d
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        openConnection()
    }

    override public func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
    }

    override public func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
    }

    override public func broadcastFinished() {
        // User has requested to finish the broadcast.
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

    private func setupConnection() {
        clientConnection?.didClose = { [weak self] error in
            logger.log(level: .debug, "client connection did close \(String(describing: error))")

            if let error {
                self?.finishBroadcastWithError(error)
            } else {
                // the displayed failure message is more user friendly when using NSError instead of Error
                let LKScreenSharingStopped = 10001
                let customError = NSError(domain: RPRecordingErrorDomain, code: LKScreenSharingStopped, userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped"])
                self?.finishBroadcastWithError(customError)
            }
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
}

#endif
