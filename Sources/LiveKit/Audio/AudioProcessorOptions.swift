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

@objc
public class AudioProcessorOptions: NSObject {
    public var capturePostProcessor: AudioProcessor?
    public var capturePostBypass: Bool = false

    public var renderPreProcessor: AudioProcessor?
    public var renderPreBypass: Bool = false

    public init(capturePostProcessor: AudioProcessor? = nil,
                capturePostBypass: Bool? = false,
                renderPreProcessor: AudioProcessor? = nil,
                renderPreBypass: Bool? = false)
    {
        self.capturePostProcessor = capturePostProcessor
        self.capturePostBypass = capturePostBypass ?? false
        self.renderPreProcessor = renderPreProcessor
        self.renderPreBypass = renderPreBypass ?? false
    }
}
