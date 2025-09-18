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

import Combine

@available(iOS 15, *)
extension ObservableObject {
    typealias BufferedObjectWillChangePublisher = Publishers.Buffer<ObjectWillChangePublisher>

    // This is necessary due to ObservableObjectPublisher not respecting the demand.
    // See: https://forums.swift.org/t/asyncpublisher-causes-crash-in-rather-simple-situation
    private var bufferedObjectWillChange: BufferedObjectWillChangePublisher {
        objectWillChange
            .buffer(size: 1, prefetch: .byRequest, whenFull: .dropOldest)
    }

    /// A publisher that emits the `objectWillChange` events.
    var changes: AsyncPublisher<BufferedObjectWillChangePublisher> {
        bufferedObjectWillChange.values
    }
}
