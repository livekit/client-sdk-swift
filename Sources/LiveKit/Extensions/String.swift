import Foundation

class Identity {
    let identity: String
    let publish: String?

    init(identity: String,
         publish: String?) {
        self.identity = identity
        self.publish = publish
    }
}

internal extension Livekit_ParticipantInfo {
    // parses identity string for the &publish= param of identity
    func parseIdentity() -> Identity {
        let segments = identity.split(separator: "#", maxSplits: 1)
        var publishSegment: String?
        if segments.count >= 2 {
            publishSegment = String(segments[1])
        }

        return Identity(
            identity: String(segments[0]),
            publish: publishSegment
        )
    }
}
