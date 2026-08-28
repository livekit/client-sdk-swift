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

internal import LiveKitWebRTC

@objcMembers
public class RemoteVideoTrack: Track, RemoteTrackProtocol, @unchecked Sendable {
    init(name: String,
         source: Track.Source,
         track: RTCMediaTrack,
         reportStatistics: Bool)
    {
        super.init(name: name,
                   kind: .video,
                   source: source,
                   track: track,
                   reportStatistics: reportStatistics)
    }
}

// MARK: - VideoTrack Protocol

extension RemoteVideoTrack: VideoTrackProtocol {
    /// - Note: Attaching a renderer blocks the calling thread until WebRTC's worker thread accepts
    ///   the sink; prefer letting ``VideoView`` manage the attach, which hops off the caller.
    public func add(videoRenderer: VideoRenderer) {
        let adapter = VideoRendererAdapter(renderer: videoRenderer)

        _state.mutate {
            $0.videoRendererAdapters.setObject(adapter, forKey: videoRenderer)
        }

        mediaTrack.blocking {
            guard let rtcVideoTrack = $0 as? LKRTCVideoTrack else {
                log("mediaTrack is not a RTCVideoTrack", .error)
                return
            }
            rtcVideoTrack.add(adapter)
        }
    }

    /// - Note: Detaching a renderer blocks the calling thread until WebRTC's worker thread drops
    ///   the sink.
    public func remove(videoRenderer: VideoRenderer) {
        let adapter = _state.mutate {
            let adapter = $0.videoRendererAdapters.object(forKey: videoRenderer)
            $0.videoRendererAdapters.removeObject(forKey: videoRenderer)
            return adapter
        }

        guard let adapter else {
            log("No adapter found for videoRenderer", .warning)
            return
        }

        mediaTrack.blocking {
            guard let rtcVideoTrack = $0 as? LKRTCVideoTrack else {
                log("mediaTrack is not a RTCVideoTrack", .error)
                return
            }
            rtcVideoTrack.remove(adapter)
        }
    }
}
