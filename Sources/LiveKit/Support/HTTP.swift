import Foundation
import Promises

internal class HTTP: NSObject, URLSessionDelegate {

    let operationQueue = OperationQueue()

    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: operationQueue)
    }()

    func get(url: URL) -> Promise<Data> {
        Promise<Data> { resolve, fail in
            let task = self.session.dataTask(with: url) { data, response, error in
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
