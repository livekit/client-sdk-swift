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

/// Switch the view to build, depending on the `Participant`'s `ConnectionQuality`.
///
/// > Note: References `Participant` environment object.
public struct ConnectionQualityBuilder<UnknownView: View,
                                       PoorView: View,
                                       GoodView: View,
                                       ExcellentView: View>: View {

    @EnvironmentObject var participant: Participant

    var unknownBuilder: ComponentBuilder<UnknownView>
    var poorBuilder: ComponentBuilder<PoorView>
    var goodBuilder: ComponentBuilder<GoodView>
    var excellentBuilder: ComponentBuilder<ExcellentView>

    public init(@ViewBuilder unknown: @escaping ComponentBuilder<UnknownView>,
                             @ViewBuilder poor: @escaping ComponentBuilder<PoorView>,
                             @ViewBuilder good: @escaping ComponentBuilder<GoodView>,
                             @ViewBuilder excellent: @escaping ComponentBuilder<ExcellentView>) {

        self.unknownBuilder = unknown
        self.poorBuilder = poor
        self.goodBuilder = good
        self.excellentBuilder = excellent
    }

    public var body: some View {
        switch participant.connectionQuality {
        case .unknown: return AnyView(unknownBuilder())
        case .poor: return AnyView(poorBuilder())
        case .good: return AnyView(goodBuilder())
        case .excellent: return AnyView(excellentBuilder())
        }
    }
}
