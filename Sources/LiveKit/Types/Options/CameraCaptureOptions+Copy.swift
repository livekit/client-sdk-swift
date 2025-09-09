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

@preconcurrency import AVFoundation

public extension CameraCaptureOptions {
    func copyWith(device: ValueOrAbsent<AVCaptureDevice?> = .absent,
                  position: ValueOrAbsent<AVCaptureDevice.Position> = .absent,
                  preferredFormat: ValueOrAbsent<AVCaptureDevice.Format?> = .absent,
                  dimensions: ValueOrAbsent<Dimensions> = .absent,
                  fps: ValueOrAbsent<Int> = .absent) -> CameraCaptureOptions
    {
        CameraCaptureOptions(device: device.value(ifAbsent: self.device),
                             position: position.value(ifAbsent: self.position),
                             preferredFormat: preferredFormat.value(ifAbsent: self.preferredFormat),
                             dimensions: dimensions.value(ifAbsent: self.dimensions),
                             fps: fps.value(ifAbsent: self.fps))
    }
}
