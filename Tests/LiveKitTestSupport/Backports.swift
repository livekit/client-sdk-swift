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

public extension URLSession {
    func downloadBackport(from url: URL) async throws -> (URL, URLResponse) {
        if #available(iOS 15.0, macOS 12.0, *) {
            try await download(from: url)
        } else {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadTask(with: url) { url, response, error in
                    if let url, let response {
                        continuation.resume(returning: (url, response))
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        fatalError("Unknown state")
                    }
                }
                task.resume()
            }
        }
    }
}
