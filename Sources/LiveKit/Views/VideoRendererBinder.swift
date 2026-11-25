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

@preconcurrency import AVFoundation

/// Keeps a track's renderer set in sync with the newest binding a ``VideoView`` asked for.
///
/// `request` records the desired track and schedules one drain on the RTC executor if none is
/// pending, so a burst of `track` / `isEnabled` changes costs at most one detach and one attach,
/// and an older request can never land on top of a newer one. The object registered with the
/// track is the binder's own ``Sink``, a stable identity that outlives the view, so the binder can
/// still detach after the view is gone.
final class VideoRendererBinder: Sendable {
    /// Registered with the track in place of the view; forwards to the view while it exists.
    final class Sink: NSObject, VideoRenderer, @unchecked Sendable {
        /// Written once by the owning view right after `super.init`, before any request can attach
        /// the sink to a track, so no read races the write.
        nonisolated(unsafe) weak var target: VideoRenderer?

        @MainActor var isAdaptiveStreamEnabled: Bool { target?.isAdaptiveStreamEnabled ?? false }
        @MainActor var adaptiveStreamSize: CGSize { target?.adaptiveStreamSize ?? .zero }

        func set(size: CGSize) {
            target?.set?(size: size)
        }

        // Tracks invoke both optional callbacks; a view subclass may implement either.
        func render(frame: VideoFrame) {
            target?.render?(frame: frame)
        }

        func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
            target?.render?(frame: frame, captureDevice: captureDevice, captureOptions: captureOptions)
        }
    }

    private struct State {
        weak var desired: (any VideoTrackProtocol)?
        weak var applied: (any VideoTrackProtocol)?
        var isDrainScheduled = false
    }

    let sink = Sink()
    private let state = StateSync(State())

    deinit {
        guard let applied = state.read({ $0.applied }) else { return }
        let sink = sink
        RTC.park { applied.remove(videoRenderer: sink) }
    }

    /// Asks for `track` to be the one track feeding the sink; `nil` detaches. Returns at once.
    func request(_ track: (any VideoTrackProtocol)?) {
        let needsDrain = state.mutate {
            $0.desired = track
            let needsDrain = !$0.isDrainScheduled
            $0.isDrainScheduled = true
            return needsDrain
        }
        guard needsDrain else { return }
        Task { @RTC in self.drain() }
    }

    @RTC
    private func drain() {
        let (applied, desired) = state.mutate {
            $0.isDrainScheduled = false
            return ($0.applied, $0.desired)
        }
        guard applied !== desired else { return }
        applied?.remove(videoRenderer: sink)
        desired?.add(videoRenderer: sink)
        state.mutate { $0.applied = desired }
    }
}
