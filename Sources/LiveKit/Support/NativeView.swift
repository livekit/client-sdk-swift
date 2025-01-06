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

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(iOS) || os(visionOS) || os(tvOS)
public typealias NativeViewType = UIView
#elseif os(macOS)
public typealias NativeViewType = NSView
#endif

/// A simple abstraction of a View that is native to the platform.
/// When built for iOS this will be a UIView.
/// When built for macOS this will be a NSView.
open class NativeView: NativeViewType {
    override public init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
    override public func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #else
    override public func layout() {
        super.layout()
        performLayout()
    }
    #endif

    #if os(macOS)
    // for compatibility with macOS
    public func setNeedsLayout() {
        needsLayout = true
    }
    #endif

    #if os(macOS)
    public func bringSubviewToFront(_ view: NSView) {
        addSubview(view)
    }

    public func insertSubview(_ view: NSView, belowSubview: NSView) {
        addSubview(view, positioned: .below, relativeTo: belowSubview)
    }
    #endif

    open func performLayout() {
        //
    }
}
