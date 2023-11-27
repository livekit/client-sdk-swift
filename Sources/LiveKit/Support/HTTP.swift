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
import Promises

internal class HTTP: NSObject, URLSessionDelegate {

    private let operationQueue = OperationQueue()

    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: operationQueue)
    }()

    func get(on: DispatchQueue, url: URL) -> Promise<Data> {

        Promise<Data>(on: on) { resolve, fail in

            let request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                     timeoutInterval: .defaultHTTPConnect)

            let task = self.session.dataTask(with: request) { data, _, error in
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
