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

internal protocol DisplayLink {
    var onFrame: ((DisplayLinkFrame) -> Void)? { get set }
    var isPaused: Bool { get set }
}

internal struct DisplayLinkFrame {
    // The system timestamp for the frame to be drawn
    var timestamp: TimeInterval
    // The duration between each display update
    var duration: TimeInterval
}

#if os(iOS)

import QuartzCore

typealias PlatformDisplayLink = iOSDisplayLink

internal class iOSDisplayLink: DisplayLink {

    var onFrame: ((DisplayLinkFrame) -> Void)?

    var isPaused: Bool {
        get { _displayLink.isPaused }
        set { _displayLink.isPaused = newValue }
    }

    let _displayLink: CADisplayLink

    let _target = DisplayLinkTarget()

    init() {
        _displayLink = CADisplayLink(target: _target, selector: #selector(DisplayLinkTarget.frame(_:)))
        _displayLink.isPaused = true
        _displayLink.add(to: RunLoop.main, forMode: RunLoop.Mode.common)

        _target.callback = { [weak self] (frame) in
            guard let self = self else { return }
            self.onFrame?(frame)
        }
    }

    deinit {
        _displayLink.invalidate()
    }

    class DisplayLinkTarget {

        var callback: ((DisplayLinkFrame) -> Void)?

        @objc
        dynamic func frame(_ _displayLink: CADisplayLink) {

            let frame = DisplayLinkFrame(
                timestamp: _displayLink.timestamp,
                duration: _displayLink.duration)

            callback?(frame)
        }
    }
}

#elseif os(macOS)

import CoreVideo

typealias PlatformDisplayLink = macOSDisplayLink

internal class macOSDisplayLink: DisplayLink {

    var onFrame: ((DisplayLinkFrame) -> Void)?

    var isPaused: Bool = true {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused == true {
                CVDisplayLinkStop(_displayLink)
            } else {
                CVDisplayLinkStart(_displayLink)
            }
        }
    }

    private var _displayLink: CVDisplayLink = {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        return dl!
    }()

    init() {

        CVDisplayLinkSetOutputHandler(_displayLink, { [weak self] (_, inNow, inOutputTime, _, _) -> CVReturn in

            guard let self = self else { return kCVReturnSuccess }

            let frame = DisplayLinkFrame(
                timestamp: inNow.pointee.timeInterval,
                duration: inOutputTime.pointee.timeInterval - inNow.pointee.timeInterval)

            self.onFrame?(frame)

            return kCVReturnSuccess
        })
    }

    deinit {
        isPaused = true
    }
}

internal extension CVTimeStamp {

    var timeInterval: TimeInterval {
        TimeInterval(videoTime) / TimeInterval(videoTimeScale)
    }
}

#endif
