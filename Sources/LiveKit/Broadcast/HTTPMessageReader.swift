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

/// Incrementally read HTTP messages from a stream of bytes.
class HTTPMessageReader {
    
    private var framedMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false)
        .takeRetainedValue()
    
    enum Error: Swift.Error {
        case incomplete(Int?)
        case appendFailed
    }
    
    /// Appends the given bytes, returning the complete message if the message is complete after the operation.
    ///
    /// After a complete message is returned, the reader is reset and is ready to receive bytes for the next message.
    ///
    func append(_ data: consuming Data) throws(Error) -> HTTPMessage {
        
        let bytes = [UInt8](data)
        guard CFHTTPMessageAppendBytes(framedMessage, bytes, bytes.count) else {
            throw .appendFailed
        }
        guard CFHTTPMessageIsHeaderComplete(framedMessage) else {
            throw .incomplete(nil)
        }
        
        guard let contentLengthString = CFHTTPMessageCopyHeaderFieldValue(
            framedMessage,
            HTTPMessage.HeaderKey.contentLength.rawValue as CFString
        )?.takeRetainedValue(),
            let body = CFHTTPMessageCopyBody(framedMessage)?.takeRetainedValue()
        else {
            throw .incomplete(nil)
        }
        
        let contentLength = Int(CFStringGetIntValue(contentLengthString))
        let bodyLength = CFDataGetLength(body)

        let remainingBytes = contentLength - bodyLength
        
        guard remainingBytes == 0 else {
            throw .incomplete(remainingBytes)
        }
        
        let completeMessage = HTTPMessage(framedMessage)
        framedMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, false).takeRetainedValue()
        return completeMessage
    }
}
