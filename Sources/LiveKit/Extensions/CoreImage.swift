/*
 * Copyright 2025 LiveKit
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

import CoreImage

public extension CIContext {
    static func metal() -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else { return CIContext() }

        return CIContext(mtlDevice: device, options: [
            .workingFormat: CIFormat.BGRA8,
            .workingColorSpace: NSNull(),
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .allowLowPower: true,
        ])
    }
}

public extension CIImage {
    func croppedAndScaled(to rect: CGRect, highQuality: Bool = true) -> CIImage {
        let currentAspect = extent.width / extent.height
        let targetAspect = rect.width / rect.height

        var cropRect = extent

        if currentAspect > targetAspect {
            let newWidth = extent.height * targetAspect
            let xOffset = (extent.width - newWidth) / 2
            cropRect = CGRect(x: extent.origin.x + xOffset,
                              y: extent.origin.y,
                              width: newWidth,
                              height: extent.height)
        } else if currentAspect < targetAspect {
            let newHeight = extent.width / targetAspect
            let yOffset = (extent.height - newHeight) / 2
            cropRect = CGRect(x: extent.origin.x,
                              y: extent.origin.y + yOffset,
                              width: extent.width,
                              height: newHeight)
        }

        let croppedImage = cropped(to: cropRect)

        let scaleX = rect.width / cropRect.width
        let scaleY = rect.height / cropRect.height

        let transform = CGAffineTransform.identity
            .translatedBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
            .scaledBy(x: scaleX, y: scaleY)
            .translatedBy(x: rect.origin.x, y: rect.origin.y)

        return croppedImage.transformed(by: transform, highQualityDownsample: highQuality)
    }
}
