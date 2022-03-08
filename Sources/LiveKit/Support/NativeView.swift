#if os(iOS)
import UIKit
public typealias NativeViewType = UIView
#elseif os(macOS)
// macOS
import AppKit
public typealias NativeViewType = NSView
#endif

/// A simple abstraction of a View that is native to the platform.
/// When built for iOS this will be a UIView.
/// When built for macOS this will be a NSView.
public class NativeView: NativeViewType {

    override init(frame: CGRect) {
        super.init(frame: frame)
        shouldPrepare()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if os(iOS)
    public override func layoutSubviews() {
        super.layoutSubviews()
        shouldLayout()
    }
    #else
    public override func layout() {
        super.layout()
        shouldLayout()
    }
    #endif

    func markNeedsLayout() {
        #if os(iOS)
        setNeedsLayout()
        #else
        needsLayout = true
        #endif
    }

    func shouldPrepare() {
        //
    }

    func shouldLayout() {
        //
    }
}
