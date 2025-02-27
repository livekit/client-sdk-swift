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

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

import CoreServices

/// Basic information about a file required to send it over a data stream.
struct FileInfo: Equatable {
    let name: String
    let size: Int
    let mimeType: String?
}

extension FileInfo {
    /// Reads information from the file located at the given URL.
    init?(for fileURL: URL) {
        var resourceKeys: Set<URLResourceKey> = [.nameKey, .fileSizeKey]
        if #available(macOS 11.0, iOS 14.0, *) {
            resourceKeys.insert(.contentTypeKey)
        }

        guard let resourceValues = try? fileURL.resourceValues(forKeys: resourceKeys),
              let name = resourceValues.name,
              let size = resourceValues.fileSize else { return nil }

        self.name = name
        self.size = size

        guard #available(macOS 11.0, iOS 14.0, *) else {
            guard let uti = UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassFilenameExtension,
                fileURL.pathExtension as CFString,
                nil
            )?.takeRetainedValue() else {
                return nil
            }
            mimeType = UTTypeCopyPreferredTagWithClass(
                uti,
                kUTTagClassMIMEType
            )?.takeRetainedValue() as? String
            return
        }

        mimeType = resourceValues.contentType?.preferredMIMEType
    }
}

extension FileInfo {
    /// Returns the preferred file extension for the given MIME type.
    static func preferredExtension(for mimeType: String) -> String? {
        guard mimeType != "application/octet-stream" else {
            // Special case not handled by UTType
            return "bin"
        }
        guard #available(macOS 11.0, iOS 14.0, *) else {
            guard let uti = UTTypeCreatePreferredIdentifierForTag(
                kUTTagClassMIMEType,
                mimeType as CFString,
                nil
            )?.takeRetainedValue() else {
                return nil
            }
            guard let fileExtension = UTTypeCopyPreferredTagWithClass(
                uti,
                kUTTagClassFilenameExtension
            )?.takeRetainedValue() else {
                return nil
            }
            return fileExtension as String
        }
        guard let utType = UTType(mimeType: mimeType) else { return nil }
        return utType.preferredFilenameExtension
    }
}
