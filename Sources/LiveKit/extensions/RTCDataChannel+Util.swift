import WebRTC

extension RTCDataChannel {

    struct labels {
        static let reliable = "_reliable"
        static let lossy = "_lossy"
    }

//    var unpackedTrackLabel: (String, String, String) {
//        let parts = label.split(separator: Character("|"))
//        guard parts.count != 3 else {
//            return ("", "", "")
//        }
//        return (String(parts[0]), String(parts[1]), String(parts[2]))
//    }
}
