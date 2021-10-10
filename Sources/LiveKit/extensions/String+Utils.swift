
extension String {

    internal func unpack() -> (sid: Sid, trackId: String) {
        let parts = split(separator: "|")
        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        }
        return (self, "")
    }
}
