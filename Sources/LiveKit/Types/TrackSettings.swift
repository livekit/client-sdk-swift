internal struct TrackSettings {

    let enabled: Bool
    let dimensions: Dimensions

    init(enabled: Bool = true,
         dimensions: Dimensions = .zero) {

        self.enabled = enabled
        self.dimensions = dimensions
    }

    func copyWith(enabled: Bool? = nil, dimensions: Dimensions? = nil) -> TrackSettings {
        TrackSettings(enabled: enabled ?? self.enabled,
                      dimensions: dimensions ?? self.dimensions)
    }
}

extension TrackSettings: Equatable {

    static func == (lhs: TrackSettings, rhs: TrackSettings) -> Bool {
        lhs.enabled == rhs.enabled && lhs.dimensions == rhs.dimensions
    }
}

extension TrackSettings: CustomStringConvertible {

    var description: String {
        "TrackSettings(enabled: \(enabled), dimensions: \(dimensions))"
    }
}
