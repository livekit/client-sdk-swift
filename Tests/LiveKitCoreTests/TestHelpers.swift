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

@testable import LiveKit
import Testing

/// Awaits `task` and asserts it threw a `LiveKitError` with the expected
/// `type`. Records a test issue if it succeeded or threw a different error.
///
/// The `sourceLocation` default forwards the caller's location so failures
/// point at the test, not this helper.
func expectLiveKitError(
    _ expected: LiveKitErrorType,
    from task: Task<some Sendable, Error>,
    sourceLocation: SourceLocation = #_sourceLocation,
) async {
    do {
        _ = try await task.value
        Issue.record("Expected LiveKitError(.\(expected)) to be thrown", sourceLocation: sourceLocation)
    } catch let error as LiveKitError {
        #expect(error.type == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Expected LiveKitError, got \(error)", sourceLocation: sourceLocation)
    }
}

/// Yields until `completer` reports at least one registered waiter — used
/// when a Task awaits on a completer and the test needs to act only after
/// the wait has parked.
func waitForRegistration(of completer: AsyncCompleter<some Any>) async {
    while completer.waiterCount == 0 {
        await Task.yield()
    }
}
