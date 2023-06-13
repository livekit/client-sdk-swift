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

/// Subclass to customize default components UI.
open class UIPreference: ObservableObject {

    enum TextFieldType {
        case url
        case token
    }

    enum ButtonType {
        case connect
    }

    var paddingSmall: CGFloat { 5 }

    /// Spacing between ``ParticipantView``s.
    var participantViewSpacing: CGFloat { 8 }

    /// Placeholder view when the video is disabled or not available.
    func videoDisabledView(geometry: GeometryProxy) -> some View {
        Image(systemName: "video.slash")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(Color(.lightGray))
            .frame(width: min(geometry.size.width, geometry.size.height) * 0.3)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
    }

    func micEnabledView() -> some View {
        Image(systemName: "mic.fill")
            .foregroundColor(.orange)
    }

    /// Placeholder view when the microphone is disabled or not available.
    func micDisabledView() -> some View {
        Image(systemName: "mic.slash.fill")
            .foregroundColor(.red)
    }

    func enableVideoView() -> some View {
        Image(systemName: "video.slash.fill")
    }

    func disableVideoView() -> some View {
        Image(systemName: "video.fill")
            .foregroundColor(.green)
    }

    func enableMicrophoneView() -> some View {
        Image(systemName: "mic.slash.fill")
    }

    func disableMicrophoneView() -> some View {
        Image(systemName: "mic.fill")
            .foregroundColor(.orange)
    }

    func disconnectView() -> some View {
        Image(systemName: "xmark.circle.fill")
            .foregroundColor(.red)
    }

    func textFieldContainer(_ childView: () -> some View, label: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10.0) {
            label()
                .fontWeight(.bold)
            childView()
                .padding()
                .overlay(RoundedRectangle(cornerRadius: 10.0)
                            .strokeBorder(Color.white.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 1.0)))
        }
    }

    func textField(for text: Binding<String>, type: TextFieldType) -> some View {
        TextField("", text: text)
            .textFieldStyle(PlainTextFieldStyle())
            .disableAutocorrection(true)
        // TODO: add iOS unique view modifiers
        #if os(iOS)
        .autocapitalization(.none)
        // .keyboardType(type.toiOSType())
        #endif
    }

    func button(_ action: @escaping () -> Void, label: () -> some View) -> some View {
        Button(action: action, label: label)
    }

    func connectionQualityIndicatorBuilder(connectionQuality: ConnectionQuality) -> some View {

        if connectionQuality == .excellent {
            return Image(systemName: "wifi")
                .foregroundColor(.green)
        } else if connectionQuality == .good {
            return Image(systemName: "wifi")
                .foregroundColor(Color.orange)
        }

        return Image(systemName: "wifi.exclamationmark")
            .foregroundColor(Color.red)
    }
}
