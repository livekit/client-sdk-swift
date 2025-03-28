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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public class RemoteVideoTrack: Track, RemoteTrack, @unchecked Sendable {
    init(name: String,
         source: Track.Source,
         track: LKRTCMediaStreamTrack,
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

extension RemoteVideoTrack: VideoTrack {
    public func add(videoRenderer: VideoRenderer) {
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        _state.mutate {
            $0.videoRenderers.add(videoRenderer)
        }

        rtcVideoTrack.add(VideoRendererAdapter(target: videoRenderer))
    }

    public func remove(videoRenderer: VideoRenderer) {
        guard let rtcVideoTrack = mediaTrack as? LKRTCVideoTrack else {
            log("mediaTrack is not a RTCVideoTrack", .error)
            return
        }

        _state.mutate {
            $0.videoRenderers.remove(videoRenderer)
        }

        rtcVideoTrack.remove(VideoRendererAdapter(target: videoRenderer))
    }
}
