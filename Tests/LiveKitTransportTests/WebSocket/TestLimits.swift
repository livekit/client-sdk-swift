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

import Testing

extension Tag {
    @Tag static var networking: Self
}

enum TestLimits {
    static var unit: any SuiteTrait {
        if #available(iOS 16, macOS 13, tvOS 16, visionOS 1, *) {
            let limit: TimeLimitTrait = .timeLimit(.minutes(1))
            return limit
        }
        let none: Tag.List = .tags()
        return none
    }
}
