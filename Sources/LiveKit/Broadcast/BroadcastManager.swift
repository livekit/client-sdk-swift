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

#if os(iOS)

import Combine
import Foundation

#if canImport(ReplayKit)
import ReplayKit
#endif

/// Manages the broadcast state and track publication for screen sharing on iOS.
public final class BroadcastManager: Sendable {
    /// Shared broadcast manager instance.
    public static let shared = BroadcastManager()

    private struct State {
        var shouldPublishTrack = true

        var cancellable = Set<AnyCancellable>()
        let isBroadcastingSubject: CurrentValueSubject<Bool, Never>

        weak var delegate: BroadcastManagerDelegate?
    }

    private let _state: StateSync<State>

    /// A delegate for handling broadcast state changes.
    public var delegate: BroadcastManagerDelegate? {
        get { _state.delegate }
        set { _state.mutate { $0.delegate = newValue } }
    }

    /// Indicates whether a broadcast is currently in progress.
    public var isBroadcasting: Bool {
        _state.isBroadcastingSubject.value
    }

    /// A publisher that emits the current broadcast state as a Boolean value.
    public var isBroadcastingPublisher: AnyPublisher<Bool, Never> {
        _state.isBroadcastingSubject.eraseToAnyPublisher()
    }

    /// Determines whether a screen share track should be automatically published when broadcasting starts.
    ///
    /// Set this to `false` to manually manage track publication when the broadcast starts.
    ///
    public var shouldPublishTrack: Bool {
        get { _state.shouldPublishTrack }
        set { _state.mutate { $0.shouldPublishTrack = newValue } }
    }

    /// Displays the system broadcast picker, allowing the user to start the broadcast.
    ///
    /// - Note: This is merely a request and does not guarantee the user will choose to start the broadcast.
    ///
    public func requestActivation() {
        Task {
            await RPSystemBroadcastPickerView.showPicker(
                for: BroadcastBundleInfo.screenSharingExtension
            )
        }
    }

    /// Requests to stop the broadcast.
    ///
    /// If a screen share track is published, it will also be unpublished once the broadcast ends.
    /// This method has no effect if no broadcast is currently in progress.
    ///
    public func requestStop() {
        DarwinNotificationCenter.shared.postNotification(.broadcastRequestStop)
    }

    init() {
        var cancellable = Set<AnyCancellable>()
        defer { _state.mutate { $0.cancellable = cancellable } }

        let subject = CurrentValueSubject<Bool, Never>(false)

        Publishers.Merge(
            DarwinNotificationCenter.shared.publisher(for: .broadcastStarted).map { _ in true },
            DarwinNotificationCenter.shared.publisher(for: .broadcastStopped).map { _ in false }
        )
        .subscribe(subject)
        .store(in: &cancellable)

        _state = StateSync(State(isBroadcastingSubject: subject))

        subject.sink { [weak self] in
            self?._state.delegate?.broadcastManager(didChangeState: $0)
        }
        .store(in: &cancellable)
    }
}

/// A delegate protocol for receiving updates about the broadcast state.
@objc
public protocol BroadcastManagerDelegate: Sendable {
    /// Invoked when the broadcast state changes.
    /// - Parameter isBroadcasting: A Boolean value indicating whether a broadcast is currently in progress.
    func broadcastManager(didChangeState isBroadcasting: Bool)
}

private extension RPSystemBroadcastPickerView {
    /// Convenience function to show broadcast picker.
    static func showPicker(for preferredExtension: String?) {
        let view = RPSystemBroadcastPickerView()
        view.preferredExtension = preferredExtension
        view.showsMicrophoneButton = false

        let selector = NSSelectorFromString("buttonPressed:")
        guard view.responds(to: selector) else { return }
        view.perform(selector, with: nil)
    }
}

#endif
