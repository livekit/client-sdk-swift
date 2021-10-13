import Foundation
import WebRTC

extension RTCMediaConstraints {

    //    static let defaultOfferConstraints = RTCMediaConstraints(
    //        mandatoryConstraints: [
    //            kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueFalse,
    //            kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
    //        ],
    //        optionalConstraints: nil
    //    )

    static let defaultPCConstraints = RTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
    )
}
