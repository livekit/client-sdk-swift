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
    let delegates = MulticastDelegate<AppStateDelegate>(label: "AppStateDelegate")

    private init() {
        let defaultCenter = NotificationCenter.default

        #if os(iOS) || os(visionOS) || os(tvOS)
        defaultCenter.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                  object: nil,
                                  queue: _queue)
        { _ in
            self.log("UIApplication.didEnterBackground")
            self.delegates.notify { $0.appDidEnterBackground() }
        }

        defaultCenter.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                  object: nil,
                                  queue: _queue)
        { _ in
            self.log("UIApplication.willEnterForeground")
            self.delegates.notify { $0.appWillEnterForeground() }
        }

        defaultCenter.addObserver(forName: UIApplication.willTerminateNotification,
                                  object: nil,
                                  queue: _queue)
        { _ in
            self.log("UIApplication.willTerminate")
            self.delegates.notify { $0.appWillTerminate() }
        }
        #elseif os(macOS)
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                    object: nil,
                                    queue: _queue)
        { _ in
            self.log("NSWorkspace.willSleepNotification")
            self.delegates.notify { $0.appWillSleep() }
        }

        workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                    object: nil,
                                    queue: _queue)
        { _ in
            self.log("NSWorkspace.didWakeNotification")
            self.delegates.notify { $0.appDidWake() }
        }
        #endif
    }
}
