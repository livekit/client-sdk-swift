/*
 * Copyright 2026 LiveKit
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

internal import LiveKitFFI
import Foundation

extension DataStreams {
    // MARK: - Progress delegate

    /// Hands the progress of an outgoing send to the caller's closure. The core calls it inside the
    /// send, on the thread that polls it.
    final class ProgressDelegate: LiveKitFFI.StreamProgressDelegate {
        private let report: @Sendable (StreamProgress) -> Void

        init(_ report: @escaping @Sendable (StreamProgress) -> Void) {
            self.report = report
        }

        func onProgress(progress: LiveKitFFI.StreamProgress) {
            report(StreamProgress(progress))
        }
    }
}
