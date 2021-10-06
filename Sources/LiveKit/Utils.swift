//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import WebRTC

typealias DebounceCancelFunc = () -> Void
typealias DebouncFunc = () -> Void
typealias DebouncOnCreateCancelFunc = (@escaping DebounceCancelFunc) -> Void

class Utils {

    static func createDebounceFunc(wait: TimeInterval,
                                   onCreateCancelFunc: DebouncOnCreateCancelFunc? = nil,
                                   fnc: @escaping @convention(block) () -> Void) -> DebouncFunc {

        var cancelFunc: DebounceCancelFunc? = nil

        return {
            cancelFunc?()
            let work = DispatchWorkItem() { fnc() }

            // cancel func is not created until debounce fnc is actually called
            cancelFunc = {
                print("[DEBOUNCE] Cancelling previous work")
                work.cancel()
            }

            // report back the created cancel func
            onCreateCancelFunc?(cancelFunc!)

            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        }
    }

    static func computeEncodings(
        dimensions: Dimensions?,
        publishOptions: LocalVideoTrackPublishOptions?
    ) -> [RTCRtpEncodingParameters]? {

        let publishOptions = publishOptions ?? LocalVideoTrackPublishOptions()

        var encoding = publishOptions.encoding

        guard let dimensions = dimensions, (publishOptions.simulcast || encoding != nil) else {
            return nil
        }

        let presets = dimensions.computeSuggestedPresets()

        if (encoding == nil) {
            let p = dimensions.computeSuggestedPreset(presets: presets)
            encoding = p.encoding
        }

        guard let encoding = encoding else {
            return nil
        }

        if (!publishOptions.simulcast) {
            // not using simulcast
            return [encoding.toRTCRtpEncoding()]
        }

        // simulcast
        let midPreset = presets[1];
        let lowPreset = presets[0];

        var result: [RTCRtpEncodingParameters] = []

        result.append(encoding.toRTCRtpEncoding(rid: "f"))

        if (dimensions.width >= 960) {
            result.append(contentsOf: [
                midPreset.encoding.toRTCRtpEncoding(
                    rid: "h",
                    scaleDownBy: 2),
                lowPreset.encoding.toRTCRtpEncoding(
                    rid: "q",
                    scaleDownBy: 4)
            ])
        } else {
            result.append(lowPreset.encoding.toRTCRtpEncoding(
                rid: "h",
                scaleDownBy: 2
                )
            )
        }

        return result
    }


    //    func getVideoEncodings(_ baseEncoding: VideoEncoding?, simulcast: Bool) -> [RTCRtpEncodingParameters] {
    //        var rtcEncodings: [RTCRtpEncodingParameters] = []
    ////        let baseParams = VideoPreset.getRTPEncodingParams(
    ////            inputWidth: dimensions.width,
    ////            inputHeight: dimensions.height,
    ////            rid: simulcast ? "f" : nil,
    ////            encoding: baseEncoding
    ////        )
    ////
    ////        if baseParams != nil {
    ////            rtcEncodings.append(baseParams!)
    ////        }
    //
    ////        if simulcast {
    ////            let halfParams = VideoPreset.getRTPEncodingParams(
    ////                inputWidth: dimensions.width,
    ////                inputHeight: dimensions.height,
    ////                rid: "h")
    ////            if halfParams != nil {
    ////                rtcEncodings.append(halfParams!)
    ////            }
    ////            let quarterParams = VideoPreset.getRTPEncodingParams(
    ////                inputWidth: dimensions.width,
    ////                inputHeight: dimensions.height,
    ////                rid: "q")
    ////            if quarterParams != nil {
    ////                rtcEncodings.append(quarterParams!)
    ////            }
    ////        }
    ////        {
    //        let p1 = RTCRtpEncodingParameters()
    //        p1.isActive = true
    //        p1.rid = "f"
    //        p1.scaleResolutionDownBy = NSNumber(value :1)// NSNumber(value: scaleDownFactor)
    //        p1.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p1.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p1)
    //
    //        let p2 = RTCRtpEncodingParameters()
    //        p2.isActive = true
    //        p2.rid = "h"
    //        p2.scaleResolutionDownBy = NSNumber(value :2)// NSNumber(value: scaleDownFactor)
    //        p2.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p2.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p2)
    //
    //
    //        let p3 = RTCRtpEncodingParameters()
    //        p3.isActive = true
    //        p3.rid = "q"
    //        p3.scaleResolutionDownBy = NSNumber(value :4)// NSNumber(value: scaleDownFactor)
    //        p3.maxFramerate = NSNumber(value: 15) //NSNumber(value: selectedEncoding.maxFps)
    //        p3.maxBitrateBps = NSNumber(value: 500 * 1024) //NSNumber(value: selectedEncoding.maxBitrate)
    //        rtcEncodings.append(p3)
    //
    //
    ////        }
    //
    //        return rtcEncodings
    //    }

}
