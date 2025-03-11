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
import XCTest

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> some Any) async {
    do {
        _ = try await expression()
        XCTFail("No error was thrown.")
    } catch {
        // Pass
    }
}

// Support iOS 13
public extension URLSession {
    func downloadBackport(from url: URL) async throws -> (URL, URLResponse) {
        if #available(iOS 15.0, macOS 12.0, *) {
            return try await download(from: url)
        } else {
            return try await withCheckedThrowingContinuation { continuation in
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

// Support for Xcode 14.2
#if !compiler(>=5.8)
extension XCTestCase {
    func fulfillment(of expectations: [XCTestExpectation], timeout: TimeInterval, enforceOrder: Bool = false) async {
        await withCheckedContinuation { continuation in
            // This function operates by blocking a background thread instead of one owned by libdispatch or by the
            // Swift runtime (as used by Swift concurrency.) To ensure we use a thread owned by neither subsystem, use
            // Foundation's Thread.detachNewThread(_:).
            Thread.detachNewThread { [self] in
                wait(for: expectations, timeout: timeout, enforceOrder: enforceOrder)
                continuation.resume()
            }
        }
    }
}
#endif
