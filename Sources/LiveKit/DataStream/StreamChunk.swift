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

public protocol StreamChunk {
    init?(_ chunkData: Data)
}

extension Data: StreamChunk {}

extension String: StreamChunk {
    public init?(_ chunkData: Data) {
        guard let string = String(data: chunkData, encoding: .utf8) else {
            return nil
        }
        self = string
    }
}

extension StreamReader where Element: RangeReplaceableCollection {
    func readAll() async throws -> Element {
        try await reduce(Element()) { $0 + $1 }
    }
}
