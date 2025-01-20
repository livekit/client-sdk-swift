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

public class ProcessingChain<T: ChainedProcessor>: NSObject, Loggable {
    // MARK: - Public properties

    public var isProcessorsEmpty: Bool { countProcessors == 0 }

    public var isProcessorsNotEmpty: Bool { countProcessors != 0 }

    public var countProcessors: Int {
        _state.read { $0.processors.compactMap(\.value).count }
    }

    public var allProcessors: [T] {
        _state.read { $0.processors.compactMap(\.value) }
    }

    // MARK: - Private properties

    private struct State {
        var processors = [WeakRef<T>]()
    }

    private let _state = StateSync(State())

    public func add(processor: T) {
        _state.mutate { $0.processors.append(WeakRef(processor)) }
    }

    public func remove(processor: T) {
        _state.mutate {
            $0.processors.removeAll { weakRef in
                guard let value = weakRef.value else { return false }
                return value === processor
            }
        }
    }

    public func removeAllProcessors() {
        _state.mutate { $0.processors.removeAll() }
    }

    public func buildProcessorChain() -> T? {
        let processors = _state.read { $0.processors.compactMap(\.value) }
        guard !processors.isEmpty else { return nil }

        for i in 0 ..< (processors.count - 1) {
            processors[i].nextProcessor = processors[i + 1]
        }
        // The last one doesn't have a successor
        processors.last?.nextProcessor = nil

        return processors.first
    }

    public func invokeProcessor<R>(_ fnc: @escaping (T) -> R) -> R? {
        guard let chain = buildProcessorChain() else { return nil }
        return fnc(chain)
    }
}
