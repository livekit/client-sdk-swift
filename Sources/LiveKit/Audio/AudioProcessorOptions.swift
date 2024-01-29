/*
 * Copyright 2024 LiveKit
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

public enum AudioProcessorType {
    case CapturePost
    case RenderPre
}

@objc
public class AudioProcessorOptions: NSObject {

    var process = [AudioProcessorType: AudioProcessor]()
    var bypass = [AudioProcessorType: Bool]()

    public func getCapturePostProcessor() -> AudioProcessor? {
        return process[.CapturePost]
    }

    public func capturePostProcessorBypass() -> Bool? {
        return bypass[.CapturePost]
    }

    public func getRenderPreProcessor() -> AudioProcessor? {
        return process[.RenderPre]
    }

    public func renderPreProcessorBypass() -> Bool? {
        return bypass[.RenderPre]
    }

    public init(
        capturePost: AudioProcessor? = nil,
        bypassCapturePost: Bool? = nil,
        renderPre: AudioProcessor? = nil,
        bypassRenderPre: Bool? = nil
    ) {
        if let capturePost = capturePost {
            process[.CapturePost] = capturePost
            bypass[.CapturePost] = bypassCapturePost ?? false
        }
    
        if let renderPre = renderPre {
            process[.RenderPre] = renderPre
            bypass[.RenderPre] = bypassRenderPre ?? false
        }
    }
}
