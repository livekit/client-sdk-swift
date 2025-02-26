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

extension Collection where Index == Int {
    func chunks(of size: Int) -> [SubSequence] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            self[$0..<Swift.min($0.advanced(by: size), count)]
        }
    }
}
