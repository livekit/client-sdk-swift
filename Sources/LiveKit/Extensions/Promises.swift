import Foundation
import Promises

extension Sequence where Element == Promise<Void> {

    func all(on queue: DispatchQueue = .promises) -> Promise<Void> {
        Promises.all(on: queue, self).then(on: queue) { _ in }
    }
}
