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

@Suite(.tags(.concurrency), TestLimits.unit)
struct StateSyncTests {
    private final class Storage {}

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func snapshotIsSkippedOnlyForOptIn() {
        let state = StateSync(Storage())
        let defaultUnique = state.mutate { isKnownUniquelyReferenced(&$0) }
        #expect(!defaultUnique)
        let optInUnique = state.mutateWithoutObservation { isKnownUniquelyReferenced(&$0) }
        #expect(optInUnique)
    }

    @Test(.bug("https://github.com/livekit/client-sdk-swift/pull/1191"))
    func observerReceivesOldAndNewValuesSynchronously() {
        let observed = StateSync<[(new: [Int]?, old: [Int]?)]>([])
        let state = StateSync<[Int]?>(nil, onDidMutate: { new, old in
            observed.mutate { $0.append((new, old)) }
        })
        state.mutate { $0 = [1] }
        #expect(observed.read { $0.count } == 1)
        state.mutate { $0?.append(2) }
        #expect(observed.read { $0.count } == 2)
        #expect(observed.read { $0.first?.old } == nil)
        #expect(observed.read { $0.first?.new } == [1])
        #expect(observed.read { $0.last?.old } == [1])
        #expect(observed.read { $0.last?.new } == [1, 2])
        state.mutate { $0 = nil }
        #expect(observed.read { $0.count } == 3)
        #expect(observed.read { $0.last?.old } == [1, 2])
        #expect(observed.read { $0.last?.new } == nil)
        state.onDidMutate = nil
        state.mutate { $0 = [3] }
        #expect(observed.read { $0.count } == 3)
    }
}
