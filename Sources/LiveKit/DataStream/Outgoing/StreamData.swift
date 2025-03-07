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

/// Type that can be sent over a data stream.
protocol StreamData: Chunkable where SubSequence: DataRepresentable {}

/// Type that can be converted to bytes losslessly.
protocol DataRepresentable {
    var dataRepresentation: Data { get }
}

/// Collection that can be divided into equally sized chunks.
protocol Chunkable: Collection {
    func chunks(of size: Int) -> [SubSequence]
}

// MARK: - Data conformance

extension Data: StreamData {}

extension Data: DataRepresentable {
    var dataRepresentation: Data { self }
}

// MARK: - String conformance

extension String: StreamData {}

extension Substring: DataRepresentable {
    var dataRepresentation: Data { Data(utf8) }
}

// MARK: - Default implementations

/// For collections that are indexed by Int.
extension Chunkable where Self: Collection, Index == Int {
    func chunks(of size: Int) -> [SubSequence] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: startIndex, to: endIndex, by: size).map {
            let end = index($0, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return self[$0 ..< end]
        }
    }
}

/// For collections that are not indexed by Int (i.e. String).
extension Chunkable where Self: Collection {
    func chunks(of size: Int) -> [SubSequence] {
        guard size > 0, !isEmpty else { return [] }

        var result: [SubSequence] = []
        var currentIndex = startIndex

        while currentIndex < endIndex {
            let nextIndex = index(currentIndex, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[currentIndex ..< nextIndex])
            currentIndex = nextIndex
        }
        return result
    }
}
