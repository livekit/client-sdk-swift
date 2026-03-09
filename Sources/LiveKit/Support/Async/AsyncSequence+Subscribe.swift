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

import Combine
import Foundation

extension AsyncSequence where Element: Sendable, Self: Sendable {
    /// Subscribe to an AsyncSequence with a lifecycle tied to an observer.
    ///
    /// The loop automatically terminates if the observer is deallocated.
    ///
    /// - Parameters:
    ///   - observer: The observer object (captured weakly).
    ///   - priority: The priority of the task.
    ///   - state: The initial mutable state.
    ///   - onElement: Called for each element.
    ///   - onFailure: Called when the sequence terminates with an error. Cancellation errors are ignored.
    /// - Returns: The task cancellable.
    func subscribe<O: AnyObject & Sendable, State: Sendable>(
        _ observer: O,
        priority: TaskPriority? = nil,
        state: State,
        onElement: @escaping @Sendable (O, Element, inout State) async -> Void,
        onFailure: (@Sendable (O, Error, inout State) async -> Void)? = nil
    ) -> AnyTaskCancellable {
        Task(priority: priority) { [weak observer] in
            var state = state
            do {
                for try await element in self {
                    guard let observer else { break }
                    await onElement(observer, element, &state)
                }
            } catch {
                if error is CancellationError { return }
                if let observer, let onFailure {
                    await onFailure(observer, error, &state)
                }
            }
        }.cancellable()
    }

    /// Subscribe to an AsyncSequence with a lifecycle tied to an observer.
    ///
    /// The loop automatically terminates if the observer is deallocated.
    ///
    /// - Parameters:
    ///   - observer: The observer object (captured weakly).
    ///   - priority: The priority of the task.
    ///   - onElement: Called for each element.
    ///   - onFailure: Called when the sequence terminates with an error. Cancellation errors are ignored.
    /// - Returns: The task cancellable.
    func subscribe<O: AnyObject & Sendable>(
        _ observer: O,
        priority: TaskPriority? = nil,
        onElement: @escaping @Sendable (O, Element) async -> Void,
        onFailure: (@Sendable (O, Error) async -> Void)? = nil
    ) -> AnyTaskCancellable {
        subscribe(
            observer,
            priority: priority,
            state: (),
            onElement: { observer, element, _ in await onElement(observer, element) },
            onFailure: { observer, error, _ in
                if let onFailure { await onFailure(observer, error) }
            }
        )
    }

    /// Subscribe to an AsyncSequence with a lifecycle tied to an observer on the MainActor.
    ///
    /// The loop automatically terminates if the observer is deallocated.
    ///
    /// - Parameters:
    ///   - observer: The observer object (captured weakly).
    ///   - priority: The priority of the task.
    ///   - state: The initial mutable state.
    ///   - onElement: Called for each element on the MainActor.
    ///   - onFailure: Called when the sequence terminates with an error on the MainActor. Cancellation errors are ignored.
    /// - Returns: The task cancellable.
    @MainActor
    func subscribeOnMainActor<O: AnyObject & Sendable, State: Sendable>(
        _ observer: O,
        priority: TaskPriority? = nil,
        state: State,
        onElement: @escaping @MainActor (O, Element, inout State) async -> Void,
        onFailure: (@MainActor (O, Error, inout State) async -> Void)? = nil
    ) -> AnyTaskCancellable {
        Task(priority: priority) { @MainActor [weak observer] in
            var state = state
            do {
                for try await element in self {
                    guard let observer else { break }
                    await onElement(observer, element, &state)
                }
            } catch {
                if error is CancellationError { return }
                if let observer, let onFailure {
                    await onFailure(observer, error, &state)
                }
            }
        }.cancellable()
    }

    /// Subscribe to an AsyncSequence with a lifecycle tied to an observer on the MainActor.
    ///
    /// The loop automatically terminates if the observer is deallocated.
    ///
    /// - Parameters:
    ///   - observer: The observer object (captured weakly).
    ///   - priority: The priority of the task.
    ///   - onElement: Called for each element on the MainActor.
    ///   - onFailure: Called when the sequence terminates with an error on the MainActor. Cancellation errors are ignored.
    /// - Returns: The task cancellable.
    @MainActor
    func subscribeOnMainActor<O: AnyObject & Sendable>(
        _ observer: O,
        priority: TaskPriority? = nil,
        onElement: @escaping @MainActor (O, Element) async -> Void,
        onFailure: (@MainActor (O, Error) async -> Void)? = nil
    ) -> AnyTaskCancellable {
        subscribeOnMainActor(
            observer,
            priority: priority,
            state: (),
            onElement: { observer, element, _ in await onElement(observer, element) },
            onFailure: { observer, error, _ in
                if let onFailure { await onFailure(observer, error) }
            }
        )
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
        #if swift(>=6.0)
        _cancel = task.cancel
        #else
        _cancel = { @Sendable in task.cancel() }
        #endif
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

    func store<C: RangeReplaceableCollection>(in collection: inout C) where C.Element == AnyTaskCancellable {
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
