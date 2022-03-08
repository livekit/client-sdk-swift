import SwiftUI

#if os(iOS)
import UIKit
public typealias NativeViewRepresentableType = UIViewRepresentable
#elseif os(macOS)
// macOS
import AppKit
public typealias NativeViewRepresentableType = NSViewRepresentable
#endif

// multiplatform version of UI/NSViewRepresentable
protocol NativeViewRepresentable: NativeViewRepresentableType {
    /// The type of view to present.
    associatedtype ViewType: NativeView

    func makeView(context: Self.Context) -> Self.ViewType
    func updateView(_ nsView: Self.ViewType, context: Self.Context)
    static func dismantleView(_ nsView: Self.ViewType, coordinator: Self.Coordinator)
}

extension NativeViewRepresentable {

    #if os(iOS)
    public func makeUIView(context: Context) -> Self.ViewType {
        return makeView(context: context)
    }

    public func updateUIView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleUIView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
    #elseif os(macOS)
    public func makeNSView(context: Context) -> Self.ViewType {
        return makeView(context: context)
    }

    public func updateNSView(_ view: Self.ViewType, context: Context) {
        updateView(view, context: context)
    }

    public static func dismantleNSView(_ view: Self.ViewType, coordinator: Self.Coordinator) {
        dismantleView(view, coordinator: coordinator)
    }
    #endif
}
