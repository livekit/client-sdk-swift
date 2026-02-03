/*
 * Copyright 2026 LiveKit
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

/// A thin unchecked sendable wrapper around NSMapTable.
final class MapTable<KeyType: AnyObject, ObjectType: AnyObject>: @unchecked Sendable {
    init(_ mapTable: NSMapTable<KeyType, ObjectType>) {
        self.mapTable = mapTable
    }

    static func weakToStrongObjects() -> MapTable<KeyType, ObjectType> {
        .init(.weakToStrongObjects())
    }

    func object(forKey aKey: KeyType?) -> ObjectType? {
        mapTable.object(forKey: aKey)
    }

    func removeObject(forKey aKey: KeyType?) {
        mapTable.removeObject(forKey: aKey)
    }

    func setObject(_ anObject: ObjectType?, forKey aKey: KeyType?) {
        mapTable.setObject(anObject, forKey: aKey)
    }

    var count: Int {
        mapTable.count
    }

    func objectEnumerator() -> NSEnumerator? {
        mapTable.objectEnumerator()
    }

    func removeAllObjects() {
        mapTable.removeAllObjects()
    }

    private let mapTable: NSMapTable<KeyType, ObjectType>
}
