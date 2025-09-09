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

import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(iOS) || os(visionOS) || os(tvOS)
public typealias NativeViewRepresentableType = UIViewRepresentable
#elseif os(macOS)
public typealias NativeViewRepresentableType = NSViewRepresentable
#endif

// multiplatform version of UI/NSViewRepresentable
@MainActor
public protocol NativeViewRepresentable: NativeViewRepresentableType {
    /// The type of view to present.
    associatedtype ViewType: NativeViewType

    func makeView(context: Self.Context) -> Self.ViewType
    func updateView(_ nsView: Self.ViewType, context: Self.Context)
    static func dismantleView(_ nsView: Self.ViewType, coordinator: Self.Coordinator)
}

public extension NativeViewRepresentable {
    #if os(iOS) || os(visionOS) || os(tvOS)
    func makeUIView(context: Context) -> Self.ViewType {
        makeView(context: context)
    }

    func updateUIView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleUIView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }

    #elseif os(macOS)
    func makeNSView(context: Context) -> Self.ViewType {
        makeView(context: context)
    }

    func updateNSView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    static func dismantleNSView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
    #endif
}
