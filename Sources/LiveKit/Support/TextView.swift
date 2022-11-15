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

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

internal class TextView: NativeView {

    #if os(iOS)
    private class DebugUILabel: UILabel {
        override func drawText(in rect: CGRect) {
            let textRect = super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
            super.drawText(in: textRect)
        }
    }
    private let _textView: DebugUILabel
    #elseif os(macOS)
    private let _textView: NSTextField
    #endif

    var text: String? {
        get {
            #if os(iOS)
            _textView.text
            #elseif os(macOS)
            _textView.stringValue
            #endif
        }
        set {
            #if os(iOS)
            _textView.text = newValue
            #elseif os(macOS)
            _textView.stringValue = newValue ?? ""
            #endif
        }
    }

    override init(frame: CGRect) {

        #if os(iOS)
        _textView  = DebugUILabel(frame: .zero)
        _textView.numberOfLines = 0
        _textView.adjustsFontSizeToFitWidth = false
        _textView.lineBreakMode = .byWordWrapping
        _textView.textColor = .white
        _textView.font = .systemFont(ofSize: 11)
        _textView.backgroundColor = .clear
        _textView.textAlignment = .right
        #elseif os(macOS)
        _textView = NSTextField()
        _textView.drawsBackground = false
        _textView.isBordered = false
        _textView.isEditable = false
        _textView.isSelectable = false
        _textView.font = .systemFont(ofSize: 11)
        _textView.alignment = .right
        #endif

        super.init(frame: frame)
        addSubview(_textView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func performLayout() {
        super.performLayout()
        _textView.frame = bounds
    }
}
