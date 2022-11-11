//
//  SampleHandler.swift
//  Broadcast Extension
//
//  Created by Alex-Dan Bumbu on 04.06.2021.
//

#if os(iOS)

import Promises
import OSLog
import Logging

#if canImport(ReplayKit)
import ReplayKit
#endif

open class LKSampleHandler: RPBroadcastSampleHandler {

    private var clientConnection: BroadcastUploadSocketConnection?
    private var uploader: SampleUploader?

    public var appGroupIdentifier: String? {
        return Bundle.main.infoDictionary?[BroadcastScreenCapturer.kAppGroupIdentifierKey] as? String
    }

    public var socketFilePath: String {
        guard let appGroupIdentifier = appGroupIdentifier,
              let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else {
            return ""
        }

        return sharedContainer.appendingPathComponent(BroadcastScreenCapturer.kRTCScreensharingSocketFD).path
    }

    public override init() {
        super.init()

        if let connection = BroadcastUploadSocketConnection(filePath: self.socketFilePath) {
            self.clientConnection = connection
            self.setupConnection()

            self.uploader = SampleUploader(connection: connection)
        }
    }

    override public func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.d
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
        self.openConnection()
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

            if let error = error {
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
