/*
 * Copyright 2023 LiveKit
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

import SwiftUI
import LiveKit

public struct TrackPublicationStateBuilder<OnView: View,
                                           OffView: View>: View {

    @EnvironmentObject var trackPublication: TrackPublication

    var onBuilder: ComponentBuilder<OnView>
    var offBuilder: ComponentBuilder<OffView>

    public init(@ViewBuilder on: @escaping ComponentBuilder<OnView>,
                             @ViewBuilder off: @escaping ComponentBuilder<OffView>) {

        self.onBuilder = on
        self.offBuilder = off
    }

    public var body: some View {
        if trackPublication.subscribed, !trackPublication.muted {
            return AnyView(onBuilder())
        } else {
            return AnyView(offBuilder())
        }
    }
}
