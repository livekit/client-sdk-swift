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

/// Keeps a whole readAll exclusive with respect to chunk reads, as the native reader did.
/// The runner retains only Void, not the last read's potentially large payload.
final class StreamReadSerialiser: Sendable {
    private let runner = SerialRunnerActor<Void>()

    func run<T: Sendable>(_ read: @escaping @Sendable () async throws -> T) async throws -> T {
        let result = AsyncCompleter<T>(label: "Stream read", defaultTimeout: 0)
        try await runner.run {
            try await result.resume(returning: read())
        }
        // The runner has completed successfully, so this is an already-resolved result.
        return try await result.wait()
    }
}
