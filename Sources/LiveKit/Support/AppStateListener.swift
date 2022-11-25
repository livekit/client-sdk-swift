/*
 * Copyright 2022 LiveKit
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

internal protocol AppStateDelegate: AnyObject {
    func appDidEnterBackground()
    func appWillEnterForeground()
    func appWillTerminate()
}

internal class AppStateListener: MulticastDelegate<AppStateDelegate> {

    static let shared = AppStateListener()

    private init() {
        super.init()

        let center = NotificationCenter.default

        #if os(iOS)
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIApplication.didEnterBackground")
            self.notify { $0.appDidEnterBackground() }
        }

        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIApplication.willEnterForeground")
            self.notify { $0.appWillEnterForeground() }
        }

        center.addObserver(forName: UIApplication.willTerminateNotification,
                           object: nil,
                           queue: OperationQueue.main) { (_) in

            self.log("UIApplication.willTerminate")
            self.notify { $0.appWillTerminate() }
        }
        #endif
    }
}
