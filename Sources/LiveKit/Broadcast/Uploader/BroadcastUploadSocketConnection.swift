//
//  UploadSocketConnection.swift
//  Broadcast Extension
//
//  Created by Alex-Dan Bumbu on 22/03/2021.
//  Copyright © 2021 Atlassian Inc. All rights reserved.
//

import Foundation

class BroadcastUploadSocketConnection: NSObject {
    var didOpen: (() -> Void)?
    var didClose: ((Error?) -> Void)?
    var streamHasSpaceAvailable: (() -> Void)?

    private let filePath: String
    private var socketHandle: Int32 = -1
    private var address: sockaddr_un?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private var networkQueue: DispatchQueue?
    private var shouldKeepRunning = false

    init?(filePath path: String) {
        filePath = path
        socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)

        guard socketHandle != -1 else {
            logger.log(level: .debug, "failure: create socket")
            return nil
        }
    }

    func open() -> Bool {
        logger.log(level: .debug, "open socket connection")

        guard FileManager.default.fileExists(atPath: filePath) else {
            logger.log(level: .debug, "failure: socket file missing")
            return false
        }

        guard setupAddress() == true else {
            return false
        }

        guard connectSocket() == true else {
            return false
        }

        setupStreams()

        inputStream?.open()
        outputStream?.open()

        return true
    }

    func close() {
        unscheduleStreams()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil
    }

    func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        logger.log(level: .debug, "client stream writeToStream \(length)")
        return outputStream?.write(buffer, maxLength: length) ?? 0
    }
}

extension BroadcastUploadSocketConnection: StreamDelegate {

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            logger.log(level: .debug, "client stream open completed")
            if aStream == outputStream {
                didOpen?()
            }
        case .hasBytesAvailable:
            if aStream == inputStream {
                var buffer: UInt8 = 0
                logger.log(level: .debug, "client stream hasBytesAvailable")
                let numberOfBytesRead = inputStream?.read(&buffer, maxLength: 1)
                if numberOfBytesRead == 0 && aStream.streamStatus == .atEnd {
                    logger.log(level: .debug, "server socket closed")
                    close()
                    notifyDidClose(error: nil)
                }
            }
        case .hasSpaceAvailable:
            if aStream == outputStream {
                logger.log(level: .debug, "client stream hasSpaceAvailable")
                streamHasSpaceAvailable?()
            }
        case .errorOccurred:
            logger.log(level: .debug, "client stream error occured: \(String(describing: aStream.streamError))")
            close()
            notifyDidClose(error: aStream.streamError)

        default:
            break
        }
    }
}

private extension BroadcastUploadSocketConnection {

    func setupAddress() -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard filePath.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            logger.log(level: .debug, "failure: fd path is too long")
            return false
        }

        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            filePath.withCString {
                strncpy(ptr, $0, filePath.count)
            }
        }

        address = addr
        return true
    }

    func connectSocket() -> Bool {
        guard var addr = address else {
            return false
        }

        let status = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard status == noErr else {
            logger.log(level: .debug, "failure: \(status)")
            return false
        }

        return true
    }

    func setupStreams() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)

        inputStream = readStream?.takeRetainedValue()
        inputStream?.delegate = self
        inputStream?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

        outputStream = writeStream?.takeRetainedValue()
        outputStream?.delegate = self
        outputStream?.setProperty(kCFBooleanTrue, forKey: Stream.PropertyKey(kCFStreamPropertyShouldCloseNativeSocket as String))

        scheduleStreams()
    }

    func scheduleStreams() {
        shouldKeepRunning = true

        networkQueue = DispatchQueue.global(qos: .userInitiated)
        networkQueue?.async { [weak self] in
            self?.inputStream?.schedule(in: .current, forMode: .common)
            self?.outputStream?.schedule(in: .current, forMode: .common)
            RunLoop.current.run()

            var isRunning = false

            repeat {
                isRunning = self?.shouldKeepRunning ?? false && RunLoop.current.run(mode: .default, before: .distantFuture)
            } while (isRunning)
        }
    }

    func unscheduleStreams() {
        networkQueue?.sync { [weak self] in
            self?.inputStream?.remove(from: .current, forMode: .common)
            self?.outputStream?.remove(from: .current, forMode: .common)
        }

        shouldKeepRunning = false
    }

    func notifyDidClose(error: Error?) {
        if didClose != nil {
            didClose?(error)
        }
    }
}
