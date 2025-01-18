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

import Foundation

enum DarwinNotification: String {
    case broadcastStarted = "iOS_BroadcastStarted"
    case broadcastStopped = "iOS_BroadcastStopped"
}

final class DarwinNotificationCenter: @unchecked Sendable {
    public static let shared = DarwinNotificationCenter()

    private let notificationCenter = CFNotificationCenterGetDarwinNotifyCenter()

    func postNotification(_ name: DarwinNotification) {
        CFNotificationCenterPostNotification(notificationCenter,
                                             CFNotificationName(rawValue: name.rawValue as CFString),
                                             nil,
                                             nil,
                                             true)
    }
    
    /// Returns an asynchronous sequence that emits a signal whenever a notification with the given name is received.
    func notifications(named name: DarwinNotification) -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.onTermination = { @Sendable _ in
                self.stopObserving(name)
            }
            self.startObserving(name) {
                continuation.yield()
            }
        }
    }

    private var handlers = [DarwinNotification: () -> Void]()

    private func startObserving(_ name: DarwinNotification, _ handler: @escaping () -> Void) {
        handlers[name] = handler
        CFNotificationCenterAddObserver(notificationCenter,
                                        Unmanaged.passUnretained(self).toOpaque(),
                                        Self.observationHandler,
                                        name.rawValue as CFString,
                                        nil,
                                        .deliverImmediately)
    }

    private func stopObserving(_ name: DarwinNotification) {
        CFNotificationCenterRemoveObserver(notificationCenter,
                                           Unmanaged.passUnretained(self).toOpaque(),
                                           CFNotificationName(name.rawValue as CFString),
                                           nil)
        handlers.removeValue(forKey: name)
    }

    private static let observationHandler: CFNotificationCallback = { _, observer, name, _, _ in
        guard let observer else { return }
        let center = Unmanaged<DarwinNotificationCenter>
            .fromOpaque(observer)
            .takeUnretainedValue()

        guard let rawName = name?.rawValue as String?,
              let name = DarwinNotification(rawValue: rawName),
              let matchingHandler = center.handlers[name]
        else { return }
        
        matchingHandler()
    }
}
