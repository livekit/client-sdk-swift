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

internal class Stopwatch {

    struct Entry {
        let label: String
        let time: TimeInterval
    }

    let label: String
    var start: TimeInterval
    private(set) var splits = [Entry]()

    init(label: String) {
        self.label = label
        self.start = ProcessInfo.processInfo.systemUptime
    }

    func split(label: String = "") {
        splits.append(Entry(label: label, time: ProcessInfo.processInfo.systemUptime))
    }

    func clear() {
        splits.removeAll()
        start = ProcessInfo.processInfo.systemUptime
    }
}

extension Stopwatch: CustomStringConvertible {

    var description: String {

        var e = [String]()
        var s = start
        for x in splits {
            let diff = x.time - s
            s = x.time
            e.append("\(x.label) +\(diff.round(to: 2))s")
        }

        e.append("total \((s - start).round(to: 2))s")
        return "Stopwatch(\(label), \(e.joined(separator: ", ")))"
    }
}
