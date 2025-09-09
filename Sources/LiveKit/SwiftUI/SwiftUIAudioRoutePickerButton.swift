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

import AVKit
import SwiftUI

internal import LiveKitWebRTC

#if os(iOS) || os(macOS)
public struct SwiftUIAudioRoutePickerButton: NativeViewRepresentable {
    public init() {}

    public func makeView(context _: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()

        #if os(iOS)
        routePickerView.prioritizesVideoDevices = false
        #elseif os(macOS)
        routePickerView.isRoutePickerButtonBordered = false
        #endif

        return routePickerView
    }

    public func updateView(_: AVRoutePickerView, context _: Context) {}
    public static func dismantleView(_: AVRoutePickerView, coordinator _: ()) {}
}
#endif
