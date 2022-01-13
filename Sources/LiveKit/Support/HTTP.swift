import Foundation
import Promises

internal class HTTP: NSObject, URLSessionDelegate {

    private let operationQueue = OperationQueue()

    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: operationQueue)
    }()

    func get(url: URL) -> Promise<Data> {

        Promise<Data>(on: .sdk) { resolve, fail in

            let request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: .defaultConnect)

            let task = self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    fail(error)
                    return
                }

                guard let data = data else {
                    fail(NetworkError.response(message: "data is nil"))
                    return
                }

                resolve(data)
            }
            task.resume()
        }
    }
}
