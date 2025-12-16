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
    /// Observe an AsyncSequence that might throw.
    ///
    /// - Parameters:
    ///   - sequence: The async sequence to iterate.
    ///   - observer: The observer object (captured weakly).
    ///   - onElement: Called for each element.
    ///   - onFailure: Called when the sequence terminates with an error.
    /// - Returns: The task, can be ignored if explicit cancellation is not needed.
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Sequence: AsyncSequence & Sendable>(
        _ sequence: Sequence,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        onElement: @Sendable @escaping (Observer, Sequence.Element) async -> Void,
        onFailure: @Sendable @escaping (Observer, Error) async -> Void
    ) -> AnyTaskCancellable where Sequence.Element: Sendable {
        Task(priority: priority) { [weak observer] in
            do {
                for try await element in sequence {
                    guard let observer else { break }
                    await onElement(observer, element)
                }
            } catch {
                if let observer {
                    await onFailure(observer, error)
                }
            }
        }.cancellable()
    }

    /// Observe an AsyncStream (non-throwing).
    ///
    /// - Parameters:
    ///   - stream: The async stream to iterate.
    ///   - observer: The observer object (captured weakly).
    ///   - onElement: Called for each element.
    /// - Returns: The task, can be ignored if explicit cancellation is not needed.
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Element: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        onElement: @Sendable @escaping (Observer, Element) async -> Void
    ) -> AnyTaskCancellable {
        Task(priority: priority) { [weak observer] in
            for await element in stream {
                guard let observer else { break }
                await onElement(observer, element)
            }
        }.cancellable()
    }

    /// Variant for main actor observations (UI) - for throwing sequences.
    @MainActor
    @discardableResult
    static func observingOnMainActor<Observer: AnyObject, Sequence: AsyncSequence & Sendable>(
        _ sequence: Sequence,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        onElement: @escaping (Observer, Sequence.Element) -> Void,
        onFailure: @escaping (Observer, Error) -> Void
    ) -> AnyTaskCancellable where Sequence.Element: Sendable {
        Task(priority: priority) { @MainActor [weak observer] in
            do {
                for try await element in sequence {
                    guard let observer else { break }
                    onElement(observer, element)
                }
            } catch {
                if let observer {
                    onFailure(observer, error)
                }
            }
        }.cancellable()
    }

    /// Variant for main actor observations (UI) - for AsyncStream (non-throwing).
    @MainActor
    @discardableResult
    static func observingOnMainActor<Observer: AnyObject, Element: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        onElement: @escaping (Observer, Element) -> Void
    ) -> AnyTaskCancellable {
        Task(priority: priority) { @MainActor [weak observer] in
            for await element in stream {
                guard let observer else { break }
                onElement(observer, element)
            }
        }.cancellable()
    }

    /// Variant with mutable state - for throwing sequences.
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Sequence: AsyncSequence & Sendable, State: Sendable>(
        _ sequence: Sequence,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        withMutableState initialState: State,
        onElement: @Sendable @escaping (Observer, Sequence.Element, inout State) -> Void,
        onFailure: @Sendable @escaping (Observer, Error, inout State) async -> Void
    ) -> AnyTaskCancellable where Sequence.Element: Sendable {
        Task(priority: priority) { [weak observer] in
            var state = initialState
            do {
                for try await element in sequence {
                    guard let observer else { break }
                    onElement(observer, element, &state)
                }
            } catch {
                if let observer {
                    await onFailure(observer, error, &state)
                }
            }
        }.cancellable()
    }

    /// Variant with mutable state - for AsyncStream (non-throwing).
    @discardableResult
    static func observing<Observer: AnyObject & Sendable, Element: Sendable, State: Sendable>(
        _ stream: AsyncStream<Element>,
        by observer: Observer,
        withPriority priority: TaskPriority = .medium,
        withMutableState initialState: State,
        onElement: @Sendable @escaping (Observer, Element, inout State) -> Void
    ) -> AnyTaskCancellable {
        Task(priority: priority) { [weak observer] in
            var state = initialState
            for await element in stream {
                guard let observer else { break }
                onElement(observer, element, &state)
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
