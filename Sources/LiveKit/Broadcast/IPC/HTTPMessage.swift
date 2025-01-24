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

/// A mutable HTTP message.
struct HTTPMessage {
    fileprivate var rawMessage: CFHTTPMessage
    
    /// A typed header key.
    struct HeaderKey: RawRepresentable {
        let rawValue: String
        static let contentLength = Self(rawValue: "Content-Length")
        static let contentType = Self(rawValue: "Content-Type")
    }
    
    /// Creates a new, empty response message.
    init() {
        rawMessage = CFHTTPMessageCreateResponse(nil, 200, nil, kCFHTTPVersion1_1)
            .takeRetainedValue()
    }
    
    init(_ rawMessage: consuming CFHTTPMessage) {
        self.rawMessage = rawMessage
    }
    
    /// Accesses the value associated with the given typed header key for reading and writing.
    subscript(header: HeaderKey) -> String? {
        get { self[header.rawValue] }
        set { self[header.rawValue] = newValue }
    }
    
    /// Accesses the value associated with the given header for reading and writing.
    subscript(header: String) -> String? {
        get {
            CFHTTPMessageCopyHeaderFieldValue(
                rawMessage,
                header as CFString
            )?
                .takeRetainedValue() as String?
        }
        set {
            copyOnWrite()
            CFHTTPMessageSetHeaderFieldValue(
                rawMessage,
                header as CFString,
                newValue as CFString?
            )
        }
    }
    
    /// Data in the body section of this message.
    ///
    /// - Note: When assigning this property,  the "Content-Length" header is set automatically.
    ///
    var body: Data? {
        get {
            guard let data = CFHTTPMessageCopyBody(rawMessage)?
                .takeRetainedValue() as Data? else { return nil }
            return data.isEmpty ? nil : data
        }
        set {
            copyOnWrite()
            let data = newValue ?? Data()
            CFHTTPMessageSetBody(rawMessage, data as CFData)
            self[.contentLength] = data.isEmpty ? nil : String(data.count)
        }
    }
    
    private mutating func copyOnWrite() {
        guard !isKnownUniquelyReferenced(&rawMessage) else { return }
        rawMessage = CFHTTPMessageCreateCopy(nil, rawMessage).takeRetainedValue()
    }
}

extension Data {
    /// Serializes the given HTTP message to data.
    init?(_ httpMessage: HTTPMessage) {
        guard let data = CFHTTPMessageCopySerializedMessage(
            httpMessage.rawMessage
        )?.takeRetainedValue() as Data? else { return nil }
        self = data
    }
}
