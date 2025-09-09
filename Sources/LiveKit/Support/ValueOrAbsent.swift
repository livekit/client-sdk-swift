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

/// Allows distinguishing between setting nil and no-op in copyWith operations.
public enum ValueOrAbsent<T: Sendable>: Sendable {
    case value(T)
    case absent

    func value(ifAbsent other: T) -> T {
        switch self {
        case let .value(t): t
        case .absent: other
        }
    }
}
