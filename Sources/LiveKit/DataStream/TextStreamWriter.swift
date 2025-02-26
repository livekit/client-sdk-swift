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

/// Asynchronously write to an open text stream.
@objc
public final class TextStreamWriter: NSObject, Sendable {
    /// Information about the outgoing text stream.
    @objc
    public let info: TextStreamInfo
    
    private let destination: StreamWriterDestination
    
    public var isOpen: Bool {
        get async { await destination.isOpen }
    }
    
    public func write(_ text: String) async throws {
        try await destination.write(Data(text.utf8))
    }
    
    public func close(reason: String? = nil) async throws {
        try await destination.close(reason: reason)
    }
    
    init(info: TextStreamInfo, destination: StreamWriterDestination) {
        self.info = info
        self.destination = destination
    }
}

// MARK: - Objective-C compatibility

extension TextStreamWriter {
    
    @objc
    @available(*, unavailable, message: "Use async write(_:) method instead.")
    public func write(_ text: String, completion: @escaping (Error?) -> Void) {
        Task {
            do { try await write(text) }
            catch { completion(error) }
        }
    }
    
    @objc
    @available(*, unavailable, message: "Use async close(reason:) method instead.")
    public func close(reason: String?, completion: @escaping (Error?) -> Void) {
        Task {
            do { try await close(reason: reason) }
            catch { completion(error) }
        }
    }
}
