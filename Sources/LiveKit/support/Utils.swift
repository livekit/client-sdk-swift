import Foundation
import WebRTC

typealias DebouncFunc = () -> Void

class Utils {

    static func createDebounceFunc(wait: TimeInterval,
                                   onCreateWorkItem: ((DispatchWorkItem) -> Void)? = nil,
                                   fnc: @escaping @convention(block) () -> Void) -> DebouncFunc {
        var workItem: DispatchWorkItem?
        return {
            workItem?.cancel()
            workItem = DispatchWorkItem { fnc() }
            onCreateWorkItem?(workItem!)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: workItem!)
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

        if encoding == nil {
            let preset = dimensions.computeSuggestedPreset(in: presets)
            encoding = preset.encoding
        }

        guard let encoding = encoding else {
            return nil
        }

        if !publishOptions.simulcast {
            // not using simulcast
            return [encoding.toRTCRtpEncoding()]
        }

        // simulcast
        let midPreset = presets[1]
        let lowPreset = presets[0]

        var result: [RTCRtpEncodingParameters] = []

        result.append(encoding.toRTCRtpEncoding(rid: "f"))

        if dimensions.width >= 960 {
            result.append(contentsOf: [
                midPreset.encoding.toRTCRtpEncoding(rid: "h", scaleDownBy: 2),
                lowPreset.encoding.toRTCRtpEncoding(rid: "q", scaleDownBy: 4)
            ])
        } else {
            result.append(lowPreset.encoding.toRTCRtpEncoding(rid: "h", scaleDownBy: 2))
        }

        return result
    }
}
