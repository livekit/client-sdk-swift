import Foundation
#if os(iOS)
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
        super.init(qos: .userInitiated)

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
