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
import Foundation

extension Task where Success == Void, Failure == Never {
    /// Creates a task that observes an async stream with correct weak-owner capture.
    ///
    /// This factory prevents common retain cycle bugs where `guard let self` at the start
    /// of a task inadvertently retains `self` for the entire task lifetime. The owner is
    /// passed explicitly to each iteration, so the task automatically breaks when the
    /// owner deallocates.
    ///
    /// Example usage:
    /// ```swift
    /// // Fire-and-forget (most common)
    /// Task.observing(eventStream, by: self) { owner, event in
    ///     await owner.handleEvent(event)
    /// }
    ///
    /// // With explicit cancellation (rare)
    /// let task = Task.observing(stream, by: self) { ... }
    /// task.cancel()
    /// ```
    ///
    /// The task automatically breaks when:
    /// - The owner is deallocated
    /// - The stream completes
    /// - The task is cancelled
    ///
    /// - Parameters:
    ///   - stream: The async stream to iterate.
    ///   - observer: The observer object (captured weakly).
    ///   - operation: Called for each element with the observer passed explicitly.
    /// - Returns: The task, can be ignored if explicit cancellation is not needed.
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Element: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        operation: @Sendable @escaping (Observer, Element) async -> Void
    ) -> AnyTaskCancellable {
        Task { [weak observer] in
            for await element in stream {
                guard let observer else { break }
                await operation(observer, element)
            }
        }.cancellable()
    }

    /// Variant for main actor observations (UI).
    @MainActor
    @discardableResult
    static func observingOnMainActor<Observer: AnyObject, Element: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        operation: @escaping (Observer, Element) -> Void
    ) -> AnyTaskCancellable {
        Task { @MainActor [weak observer] in
            for await element in stream {
                guard let observer else { break }
                operation(observer, element)
            }
        }.cancellable()
    }

    /// Variant with mutable state that persists across iterations.
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Element: Sendable, State: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        state initialState: State,
        operation: @Sendable @escaping (Observer, Element, inout State) -> Void
    ) -> AnyTaskCancellable {
        Task { [weak observer] in
            var state = initialState
            for await element in stream {
                guard let observer else { break }
                operation(observer, element, &state)
            }
        }.cancellable()
    }
}

extension Task {
    func cancellable() -> AnyTaskCancellable {
        AnyTaskCancellable(self)
    }
}

/// A Sendable variant of Combine's AnyCancellable.
final class AnyTaskCancellable: Cancellable, Sendable, Hashable {
    private let _cancel: @Sendable () -> Void

    init(_ task: Task<some Any, some Any>) {
        _cancel = task.cancel
    }

    deinit {
        _cancel()
    }

    func cancel() {
        _cancel()
    }

    func store(in set: inout Set<AnyTaskCancellable>) {
        set.insert(self)
    }

    func store<C>(in collection: inout C) where C: RangeReplaceableCollection, C.Element == AnyTaskCancellable {
        collection.append(self)
    }

    static func == (lhs: AnyTaskCancellable, rhs: AnyTaskCancellable) -> Bool {
        ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
}

extension AnyTaskCancellable {
    func eraseToAnyCancellable() -> AnyCancellable {
        AnyCancellable(cancel)
    }
}
