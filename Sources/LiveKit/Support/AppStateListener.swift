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

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

@objc
protocol AppStateDelegate: AnyObject, Sendable {
    func appDidEnterBackground()
    func appWillEnterForeground()
    func appWillTerminate()
    /// Only for macOS.
    func appWillSleep()
    /// Only for macOS.
    func appDidWake()
}

@MainActor
class AppStateListener: Loggable {
    static let shared = AppStateListener()

    private let _queue = OperationQueue()
    nonisolated(unsafe) private var _observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
    let delegates = MulticastDelegate<AppStateDelegate>(label: "AppStateDelegate")

    private func _addObserver(name: Notification.Name,
                              center: NotificationCenter,
                              handler: @escaping @MainActor () -> Void)
    {
        let token = center.addObserver(forName: name,
                                       object: nil,
                                       queue: _queue)
        { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                handler()
            }
        }

        _observerTokens.append((center, token))
    }

    deinit {
        for (center, token) in _observerTokens {
            center.removeObserver(token)
        }
        _observerTokens.removeAll()
    }

    private init() {
        let defaultCenter = NotificationCenter.default

        #if os(iOS) || os(visionOS) || os(tvOS)
        _addObserver(name: UIApplication.didEnterBackgroundNotification,
                     center: defaultCenter)
        { [weak self] in
            guard let self else { return }
            self.log("UIApplication.didEnterBackground")
            self.delegates.notify { $0.appDidEnterBackground() }
        }

        _addObserver(name: UIApplication.willEnterForegroundNotification,
                     center: defaultCenter)
        { [weak self] in
            guard let self else { return }
            self.log("UIApplication.willEnterForeground")
            self.delegates.notify { $0.appWillEnterForeground() }
        }

        _addObserver(name: UIApplication.willTerminateNotification,
                     center: defaultCenter)
        { [weak self] in
            guard let self else { return }
            self.log("UIApplication.willTerminate")
            self.delegates.notify { $0.appWillTerminate() }
        }
        #elseif os(macOS)
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        _addObserver(name: NSWorkspace.willSleepNotification,
                     center: workspaceCenter)
        { [weak self] in
            guard let self else { return }
            self.log("NSWorkspace.willSleepNotification")
            self.delegates.notify { $0.appWillSleep() }
        }

        _addObserver(name: NSWorkspace.didWakeNotification,
                     center: workspaceCenter)
        { [weak self] in
            guard let self else { return }
            self.log("NSWorkspace.didWakeNotification")
            self.delegates.notify { $0.appDidWake() }
        }
        #endif
    }
}
