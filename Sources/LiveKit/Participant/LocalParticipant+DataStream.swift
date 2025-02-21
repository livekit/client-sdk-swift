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

public extension LocalParticipant {
    // MARK: - Send
    
    @objc
    func sendText(_ text: String, topic: String) async throws -> TextStreamInfo {
        try await sendText(text, options: SendTextOptions(topic: topic))
    }
    
    @objc
    func sendText(_ text: String, options: SendTextOptions) async throws -> TextStreamInfo {
        fatalError("Not implemented")
    }
    
    @objc
    func sendFile(_ fileURL: URL, topic: String) async throws -> ByteStreamInfo {
        try await sendFile(fileURL, options: SendFileOptions(topic: topic))
    }
    
    @objc
    func sendFile(_ fileURL: URL, options: SendFileOptions) async throws -> ByteStreamInfo {
        fatalError("Not implemented")
    }
    
    // MARK: - Stream
    
    typealias TextStreamWriter = ()
    typealias ByteStreamWriter = ()
    
    @objc
    func streamText(topic: String) async throws -> TextStreamWriter {
        try await streamText(options: StreamTextOptions(topic: topic))
    }
    
    @objc
    func streamText(options: StreamTextOptions) async throws -> TextStreamWriter {
        fatalError("Not implemented")
    }
    
    @objc
    func streamBytes(topic: String) async throws -> ByteStreamWriter {
        try await streamBytes(options: StreamByteOptions(topic: topic))
    }
    
    @objc
    func streamBytes(options: StreamByteOptions) async throws -> ByteStreamWriter {
        fatalError("Not implemented")
    }
}
