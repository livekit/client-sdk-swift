/*
 * Copyright 2022 LiveKit
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

@available(*, deprecated)
public extension Dimensions {

    // 16:9 aspect ratio presets
    static let qvga169 = h180_169
    static let vga169 = h360_169
    static let qhd169 = h540_169
    static let hd169 = h720_169
    static let fhd169 = h1080_169

    // 4:3 aspect ratio presets
    static let qvga43 = h180_43
    static let vga43 = h360_43
    static let qhd43 = h540_43
    static let hd43 = h720_43
    static let fhd43 = h1080_43
}
