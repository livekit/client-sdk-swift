import Foundation

public struct Dimensions {
    public static let aspectRatio169 = 16.0 / 9.0
    public static let aspectRatio43 = 4.0 / 3.0

    public let width: Int
    public let height: Int
}

extension Dimensions {

    func computeSuggestedPresets() -> [VideoParameters] {
        let aspect = Double(width) / Double(height)
        if abs(aspect - Dimensions.aspectRatio169) < abs(aspect - Dimensions.aspectRatio43) {
            return VideoParameters.presets169
        }
        return VideoParameters.presets43;
    }

    func computeSuggestedPreset(in presets: [VideoParameters]) -> VideoParameters {
        assert(!presets.isEmpty)
        var result = presets[0]
        for preset in presets {
            if width >= preset.dimensions.width, height >= preset.dimensions.height {
                result = preset
            }
        }
        return result
    }
}
