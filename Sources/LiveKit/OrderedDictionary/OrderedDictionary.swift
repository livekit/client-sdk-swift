/// A generic collection for storing key-value pairs in an ordered manner.
///
/// See the following example for a brief showcase including the initialization from a dictionary
/// literal as well as iteration over its sorted key-value pairs:
///
///     let orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
///
///     print(orderedDictionary)
///     // => ["a": 1, "b": 2, "c": 3]
///
///     for (key, value) in orderedDictionary {
///         print("key=\(key), value=\(value)")
///     }
///     // => key="a", value=1
///     // => key="b", value=2
///     // => key="c", value=3
///
///     for (index, element) in orderedDictionary.enumerated() {
///         print("index=\(index), element=\(element)")
///     }
///     // => index=0, element=(key: "a", value: 1)
///     // => index=1, element=(key: "b", value: 2)
///     // => index=2, element=(key: "c", value: 3)
public struct OrderedDictionary<Key: Hashable, Value>: RandomAccessCollection, MutableCollection {
    
    // ============================================================================ //
    // MARK: - Type Aliases
    // ============================================================================ //
    
    /// The type of the key-value pair stored in the ordered dictionary.
    public typealias Element = (key: Key, value: Value)
    
    /// The type of the index.
    public typealias Index = Int
    
    /// The type of the contiguous subrange of the ordered dictionary's elements.
    public typealias SubSequence = OrderedDictionarySlice<Key, Value>

    /// The type of the lazily evaluated collection of the ordered dictionary's values.
    public typealias LazyValues = LazyMapCollection<Self, Value>
    
    // ============================================================================ //
    // MARK: - Initialization
    // ============================================================================ //
    
    /// Initializes an empty ordered dictionary.
    public init() {
        self.init(
            uniqueKeysWithValues: EmptyCollection<Element>(),
            minimumCapacity: nil
        )
    }
    
    /// Initializes an empty ordered dictionary with preallocated space for at least
    /// the specified number of elements.
    public init(minimumCapacity: Int) {
        self.init(
            uniqueKeysWithValues: EmptyCollection<Element>(),
            minimumCapacity: minimumCapacity
        )
    }
    
    /// Initializes an ordered dictionary from a regular unsorted dictionary by sorting it
    /// using the given sort function.
    ///
    /// - Parameters:
    ///   - unsorted: The unsorted dictionary.
    ///   - areInIncreasingOrder: The sort function which compares the key-value pairs.
    public init(
        unsorted: Dictionary<Key, Value>,
        areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows {
        let keysAndValues = try Array(unsorted).sorted(by: areInIncreasingOrder)
        
        self.init(
            uniqueKeysWithValues: keysAndValues,
            minimumCapacity: unsorted.count
        )
    }
    
    /// Initializes an ordered dictionary from a sequence of values keyed by a unique key
    /// extracted from the value using the given closure.
    ///
    /// - Parameters:
    ///   - values: The sequence of values.
    ///   - extractKey: The closure which extracts a key from the value. The returned keys must
    ///     be unique for all values from the sequence.
    public init<S: Sequence>(
        values: S,
        uniquelyKeyedBy extractKey: (Value) throws -> Key
    ) rethrows where S.Element == Value {
        self.init(uniqueKeysWithValues: try values.map { value in
            return (try extractKey(value), value)
        })
    }
    
    /// Initializes an ordered dictionary from a sequence of values keyed by a unique key
    /// extracted from the value using the given key path.
    ///
    /// - Parameters:
    ///   - values: The sequence of values.
    ///   - keyPath: The key path to use for extracting a key from the value. The extracted keys
    ///     must be unique for all values from the sequence.
    public init<S: Sequence>(
        values: S,
        uniquelyKeyedBy keyPath: KeyPath<Value, Key>
    ) where S.Element == Value {
        self.init(uniqueKeysWithValues: values.map { value in
            return (value[keyPath: keyPath], value)
        })
    }
    
    /// Initializes an ordered dictionary from a sequence of key-value pairs.
    ///
    /// - Parameters:
    ///   - keysAndValues: A sequence of key-value pairs to use for the new ordered dictionary.
    ///     Every key in `keysAndValues` must be unique.
    public init<S: Sequence>(
        uniqueKeysWithValues keysAndValues: S
    ) where S.Element == Element {
        self.init(
            uniqueKeysWithValues: keysAndValues,
            minimumCapacity: keysAndValues.underestimatedCount
        )
    }
    
    private init<S: Sequence>(
        uniqueKeysWithValues keysAndValues: S,
        minimumCapacity: Int?
    ) where S.Element == Element {
        defer { _assertInvariant() }
        
        var orderedKeys = [Key](minimumCapacity: minimumCapacity ?? 0)
        var keysToValues = [Key: Value](minimumCapacity: minimumCapacity ?? 0)
        
        for (key, value) in keysAndValues {
            precondition(
                keysToValues[key] == nil,
                "[OrderedDictionary] Sequence of key-value pairs contains duplicate keys (\(key))"
            )
            
            orderedKeys.append(key)
            keysToValues[key] = value
        }
        
        self._orderedKeys = orderedKeys
        self._keysToValues = keysToValues
    }
    
    // ============================================================================ //
    // MARK: - Ordered Keys & Values
    // ============================================================================ //
    
    /// An array containing just the keys of the ordered dictionary in the correct order.
    ///
    /// The following example shows how the ordered keys can be iterated over and accessed.
    ///
    ///     let orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     for key in orderedDictionary.orderedKeys {
    ///         print(key)
    ///     }
    ///     // => "a"
    ///     // => "b"
    ///     // => "c"
    ///
    ///     print(orderedDictionary.orderedKeys)
    ///     // => ["a", "b", "c"]
    public var orderedKeys: [Key] {
        return _orderedKeys
    }
    
    /// A lazily evaluated collection containing just the values of the ordered dictionary
    /// in the correct order.
    ///
    /// The following example shows how the ordered values can be iterated over and accessed.
    /// Note that the collection is of type `LazyValues` which wraps the `OrderedDictionary`
    /// as its base collection. Depending on the use case it might be desirable to convert
    /// the collection to an `Array` which creates a copy of the values.
    ///
    ///     let orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     for value in orderedDictionary.orderedValues {
    ///         print(value)
    ///     }
    ///     // => 1
    ///     // => 2
    ///     // => 3
    ///
    ///     print(Array(orderedDictionary.orderedValues))
    ///     // => [1, 2, 3]
    public var orderedValues: LazyValues {
        return self.lazy.map { $0.value }
    }
    
    // ============================================================================ //
    // MARK: - Unordered Dictionary
    // ============================================================================ //
    
    /// Converts itself to a common unsorted dictionary.
    public var unorderedDictionary: Dictionary<Key, Value> {
        return _keysToValues
    }

    // ============================================================================ //
    // MARK: - Indices
    // ============================================================================ //
    
    /// The indices that are valid for subscripting the ordered dictionary.
    public var indices: CountableRange<Index> {
        return _orderedKeys.indices
    }
    
    /// The position of the first key-value pair in a non-empty ordered dictionary.
    public var startIndex: Index {
        return _orderedKeys.startIndex
    }
    
    /// The position which is one greater than the position of the last valid key-value pair
    /// in the ordered dictionary.
    public var endIndex: Index {
        return _orderedKeys.endIndex
    }
    
    /// Returns the position immediately after the given index.
    public func index(after i: Index) -> Index {
        return _orderedKeys.index(after: i)
    }
    
    /// Returns the position immediately before the given index.
    public func index(before i: Index) -> Index {
        return _orderedKeys.index(before: i)
    }
    
    /// Returns the index for the given key.
    ///
    /// The following example shows how to get indices for given keys:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     print(orderedDictionary.index(forKey: "a"))
    ///     // => Optional(0)
    ///
    ///     print(orderedDictionary.index(forKey: "x"))
    ///     // => nil
    ///
    /// - Parameters:
    ///   - key: The key to find in the ordered dictionary.
    /// - Returns: The index for `key` and its associated value if `key` is in the ordered
    ///   dictionary; otherwise, `nil`.
    ///
    /// - Complexity: O(*n*), where *n* is the length of the ordered dictionary.
    public func index(forKey key: Key) -> Index? {
        return _orderedKeys.firstIndex(of: key)
    }
    
    // ============================================================================ //
    // MARK: - Key-based Access
    // ============================================================================ //
    
    /// Accesses the value associated with the given key for reading and writing.
    ///
    /// This key-based subscript returns the value for the given key if the key is found in the
    /// ordered dictionary, or `nil` if the key is not found.
    ///
    /// When you assign a value for a key and that key already exists, the ordered dictionary
    /// overwrites the existing value and preservers the index of the key-value pair. If the
    /// ordered dictionary does not contain the key, a new key-value pair is appended to the end
    /// of the ordered dictionary.
    ///
    /// When you assign `nil` as the value for the given key, the ordered dictionary removes
    /// that key and its associated value if it exists.
    ///
    /// See the following example that shows how to access and set values for keys:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     print(orderedDictionary["a"])
    ///     // => Optional(1)
    ///
    ///     print(orderedDictionary["x"])
    ///     // => nil
    ///
    ///     orderedDictionary["b"] = 42
    ///     print(orderedDictionary["b"])
    ///     // => Optional(42)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "b": 42, "c": 3]
    ///
    ///     orderedDictionary["d"] = 4
    ///     print(orderedDictionary["d"])
    ///     // => Optional(4)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "b": 42, "c": 3, "d": 4]
    ///
    ///     orderedDictionary["c"] = nil
    ///     print(orderedDictionary["c"])
    ///     // => nil
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "b": 42, "d": 4]
    ///
    /// - Parameters:
    ///   - key: The key to find in the ordered dictionary.
    /// - Returns: The value associated with `key` if `key` is in the ordered dictionary;
    ///   otherwise, `nil`.
    public subscript(key: Key) -> Value? {
        get {
            return value(forKey: key)
        }
        set(newValue) {
            if let newValue = newValue {
                updateValue(newValue, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }
    
    /// Returns whether whether the ordered dictionary contains the given key.
    ///
    /// - Parameter key: The key to be looked up.
    /// - Returns: `true` if the ordered dictionary contains the given key; otherwise, `false`.
    ///
    /// - SeeAlso: `subscript(key:)`
    public func containsKey(_ key: Key) -> Bool {
        return _keysToValues[key] != nil
    }
    
    /// Returns the value associated with the given key if the key is found in the ordered
    /// dictionary, or `nil` if the key is not found.
    ///
    /// The following example shows how to access values for keys:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     print(orderedDictionary.value(forKey: "a"))
    ///     // => Optional(1)
    ///
    ///     print(orderedDictionary.value(forKey: "x"))
    ///     // => nil
    ///
    /// - Parameters:
    ///   - key: The key to find in the ordered dictionary.
    /// - Returns: The value associated with `key` if `key` is in the ordered dictionary;
    ///   otherwise, `nil`.
    ///
    /// - SeeAlso: `subscript(key:)`
    public func value(forKey key: Key) -> Value? {
        return _keysToValues[key]
    }
    
    /// Updates the value stored in the ordered dictionary for the given key, or appends a new
    /// key-value pair if the key does not exist.
    ///
    /// The following example shows how to update the value for an existing key:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     let previousValue = orderedDictionary.updateValue(42, forKey: "b")
    ///
    ///     print(previousValue)
    ///     // => Optional(2)
    ///
    ///     print(orderedDictionary["b"])
    ///     // => Optional(42)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "b": 42, "c": 3]
    ///
    /// See the second example for the case where the updated key is not yet present in
    /// the ordered dictionary:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     let previousValue = orderedDictionary.updateValue(4, forKey: "d")
    ///
    ///     print(previousValue)
    ///     // => nil
    ///
    ///     print(orderedDictionary["d"])
    ///     // => Optional(4)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "b": 2, "c": 3, "d": 4]
    ///
    /// - Parameters:
    ///   - value: The new value to add to the ordered dictionary.
    ///   - key: The key to associate with `value`. If `key` already exists in the ordered
    ///     dictionary, `value` replaces the existing associated value. If `key` is not yet
    ///     a key of the ordered dictionary, the `(key, value)` pair is appended at the end
    ///     of the ordered dictionary.
    ///
    /// - SeeAlso: `subscript(key:)`
    @discardableResult
    public mutating func updateValue(
        _ value: Value,
        forKey key: Key
    ) -> Value? {
        defer { _assertInvariant() }
        
        if containsKey(key) {
            guard let currentValue = _keysToValues[key] else {
                fatalError("[OrderedDictionary] Inconsistency error")
            }
            
            _keysToValues[key] = value
            
            return currentValue
        } else {
            _orderedKeys.append(key)
            _keysToValues[key] = value
            
            return nil
        }
    }
    
    /// Removes the given key and its associated value from the ordered dictionary.
    ///
    /// If the key is found in the ordered dictionary, this method returns the key's associated
    /// value. On removal, the indices of the ordered dictionary are invalidated. If the key is 
    /// not found in the ordered dictionary, this method returns `nil`.
    ///
    /// The following example shows how to remove a value for a key:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     let removedValue = orderedDictionary.removeValue(forKey: "b")
    ///
    ///     print(removedValue)
    ///     // => Optional(2)
    ///
    ///     print(orderedDictionary["b"])
    ///     // => nil
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "c": 3]
    ///
    /// - Parameters:
    ///   - key: The key to remove along with its associated value.
    /// - Returns: The value that was removed, or `nil` if the key was not present in the 
    ///   ordered dictionary.
    ///
    /// - SeeAlso: `subscript(key:)`
    /// - SeeAlso: `remove(at:)`
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        guard let currentValue = _keysToValues[key] else { return nil }
        guard let index = index(forKey: key) else { return nil }
        
        defer { _assertInvariant() }
        
        _orderedKeys.remove(at: index)
        _keysToValues[key] = nil
        
        return currentValue
    }
    
    /// Removes all key-value pairs from the ordered dictionary and invalidates all indices.
    ///
    /// - Parameters:
    ///   - keepCapacity: Whether the ordered dictionary should keep its underlying storage.
    ///     If you pass `true`, the operation preserves the storage capacity that the collection
    ///     has, otherwise the underlying storage is released. The default is `false`.
    public mutating func removeAll(
        keepingCapacity keepCapacity: Bool = false
    ) {
        defer { _assertInvariant() }
        
        _orderedKeys.removeAll(keepingCapacity: keepCapacity)
        _keysToValues.removeAll(keepingCapacity: keepCapacity)
    }
    
    // ============================================================================ //
    // MARK: - Index-based Access
    // ============================================================================ //
    
    /// Accesses the key-value pair at the specified position for reading and writing.
    ///
    /// When accessing a key-value pair the given position must be a valid index of the ordered
    /// dictionary.
    ///
    /// When assigning a key-value pair for a particular position, the position must be either
    /// a valid index of the ordered dictionary or equal to `endIndex`. Furthermore, the given
    /// key must not be already present at a different position of the ordered dictionary.
    /// However, it is safe to set a key equal to the key that is currently present at that
    /// position.
    ///
    /// The following example shows how to access and set key-value pairs at specific indices:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     print(orderedDictionary[0])
    ///     // => (key: "a", value: 1)
    ///
    ///     orderedDictionary[1] = (key: "d", value: 42)
    ///     print(orderedDictionary[1])
    ///     // => (key: "d", value: 42)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "d": 42, "c": 3]
    ///
    ///     orderedDictionary[0] = (key: "a", value: 5)
    ///     print(orderedDictionary[0])
    ///     // => (key: "a", value: 5)
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 5, "d": 42, "c": 3]
    ///
    /// - Parameters:
    ///   - position: The position of the key-value pair to access. `position` must be a valid
    ///     index of the ordered dictionary and not equal to `endIndex`.
    /// - Returns: A tuple containing the key-value pair corresponding to `position`.
    ///
    /// - SeeAlso: `update(_:at:)`
    /// - SeeAlso: `subscript(bounds:)`
    public subscript(position: Index) -> Element {
        get {
            precondition(
                indices.contains(position),
                "[OrderedDictionary] Index is out of bounds"
            )
            
            let key = _orderedKeys[position]
            
            guard let value = _keysToValues[key] else {
                fatalError("[OrderedDictionary] Inconsistency error")
            }
            
            return (key, value)
        }
        set(newElement) {
            update(newElement, at: position)
        }
    }
    
    /// Accesses a contiguous subrange of the ordered dictionary's elements.
    ///
    /// - Parameters:
    ///   - bounds: A range of indices. The bounds of the range must be valid indices of
    ///     the ordered dictionary.
    /// - Returns: An instance of `OrderedDictionarySlice`.
    ///
    /// - Precondition: When replacing a certain range with a slice, it has to have an equal size.
    ///   Furthermore, the key-value pairs must not contain keys that are present in the ordered
    ///   dictionary, but lie outside of the replaced range. It is safe to provide the keys
    ///   from the replaced range in the different order or keys that are not present in the
    ///   ordered dictionary.
    /// - SeeAlso: `subscript(position:)`
    public subscript(bounds: Range<Index>) -> SubSequence {
        get {
            precondition(
                bounds.clamped(to: indices) == bounds,
                "[OrderedDictionary] Range is out of bounds"
            )

            return SubSequence(base: self, bounds: bounds)
        }
        set(newElements) {
            precondition(
                bounds.clamped(to: indices) == bounds,
                "[OrderedDictionary] Range is out of bounds"
            )
            
            defer { _assertInvariant() }
            
            let innerKeys = orderedKeys[bounds]
            let outerKeys = Set(orderedKeys).subtracting(innerKeys)

            let newKeys = Set(newElements.map { $0.key })

            precondition(
                newKeys.isDisjoint(with: outerKeys),
                "[OrderedDictionary] Range-based update produced duplicate keys"
            )

            // WriteBackMutableSlice.swift
            // _writeBackMutableSlice(_:bounds:slice:)
            // https://bit.ly/3lhaIA8
            var baseIndex = bounds.lowerBound
            let baseEndIndex = bounds.upperBound
            
            var sliceIndex = newElements.startIndex
            let sliceEndIndex = newElements.endIndex

            while baseIndex != baseEndIndex && sliceIndex != sliceEndIndex {
                let (newKey, newValue) = newElements[sliceIndex]

                let previousElement = self[baseIndex]
                let previousKey = previousElement.key

                // If the key of the previously stored element at the updated index is not
                // replaced as part of the range-based update operation, its value is removed.
                if !newKeys.contains(previousKey) {
                    _keysToValues.removeValue(forKey: previousKey)
                }

                _orderedKeys[baseIndex] = newKey
                _keysToValues[newKey] = newValue

                self.formIndex(after: &baseIndex)
                newElements.formIndex(after: &sliceIndex)
            }
            
            precondition(
                baseIndex == baseEndIndex,
                "[OrderedDictionary] Cannot replace a range with a slice of a smaller size"
            )
            
            precondition(
                sliceIndex == sliceEndIndex,
                "[OrderedDictionary] Cannot replace a range with a slice of a larger size"
            )
        }
    }
    
    /// Returns the key-value pair at the specified index, or `nil` if there is no key-value
    /// pair at that index.
    ///
    /// - Parameters:
    ///   - index: The index of the key-value pair to be looked up. `index` does not have to
    ///     be a valid index.
    /// - Returns: A tuple containing the key-value pair corresponding to `index` if the index
    ///   is valid; otherwise, `nil`.
    ///
    /// - SeeAlso: `subscript(position:)`
    public func elementAt(_ index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
    
    /// Checks whether a key-value pair with the given key can be inserted into the ordered
    /// dictionary by validating its presence.
    ///
    /// - Parameters:
    ///   - key: The key to be inserted into the ordered dictionary.
    /// - Returns: `true` if the key can safely be inserted; otherwise, `false`.
    ///
    /// - SeeAlso: `canInsert(at:)`
    public func canInsert(key: Key) -> Bool {
        return !containsKey(key)
    }
    
    /// Checks whether a new key-value pair can be inserted into the ordered dictionary at the
    /// given index.
    ///
    /// - Parameters:
    ///   - index: The index the new key-value pair should be inserted at.
    /// - Returns: `true` if a new key-value pair can be inserted at the specified index;
    ///   otherwise, `false`.
    ///
    /// - SeeAlso: `canInsert(key:)`
    public func canInsert(at index: Index) -> Bool {
        return index >= startIndex && index <= endIndex
    }
    
    /// Inserts a new key-value pair at the specified position.
    ///
    /// If the key of the inserted pair already exists in the ordered dictionary, a runtime error
    /// is triggered. Use `canInsert(_:)` for performing a check first, so that this method can
    /// be executed safely.
    ///
    /// - Parameters:
    ///   - newElement: The new key-value pair to insert into the ordered dictionary. The key
    ///     contained in the pair must not be already present in the ordered dictionary.
    ///   - index: The position at which to insert the new key-value pair. `index` must be
    ///     a valid index of the ordered dictionary or equal to `endIndex` property.
    ///
    /// - SeeAlso: `canInsert(key:)`
    /// - SeeAlso: `canInsert(at:)`
    /// - SeeAlso: `update(_:at:)`
    public mutating func insert(
        _ newElement: Element,
        at index: Index
    ) {
        precondition(
            canInsert(key: newElement.key),
            "[OrderedDictionary] Cannot insert duplicate key"
        )
        
        precondition(
            canInsert(at: index),
            "[OrderedDictionary] Cannot insert key-value pair at invalid index"
        )
        
        defer { _assertInvariant() }
        
        let (key, value) = newElement
        
        _orderedKeys.insert(key, at: index)
        _keysToValues[key] = value
    }
    
    /// Checks whether the key-value pair at the given index can be updated with the given
    /// key-value pair. This is not the case if the key of the updated element is already present
    /// in the ordered dictionary and located at another index than the updated one.
    ///
    /// Although this is a checking method, a valid index has to be provided.
    ///
    /// - Parameters:
    ///   - newElement: The key-value pair to be set at the specified position.
    ///   - index: The position at which to set the key-value pair. `index` must be a valid index
    ///     of the ordered dictionary.
    public func canUpdate(
        _ newElement: Element,
        at index: Index
    ) -> Bool {
        precondition(
            indices.contains(index),
            "[OrderedDictionary] Index is out of bounds"
        )
        
        let newKey = newElement.key
        
        let previousElement = self[index]
        let previousKey = previousElement.key
        
        let isSameKey = previousKey == newKey
        let isExistingKey = containsKey(newKey)
        
        return isSameKey || !isExistingKey
    }
    
    /// Updates the key-value pair located at the specified position.
    ///
    /// If the key of the updated pair already exists in the ordered dictionary *and* is located
    /// at a different position than the specified one, a runtime error is triggered.
    ///
    /// Use `canUpdate(_:at:)` to perform a check first, so that this method can be executed safely.
    ///
    /// - Parameters:
    ///   - newElement: The key-value pair to be set at the specified position.
    ///   - index: The position at which to set the key-value pair. `index` must be a valid index
    ///     of the ordered dictionary.
    /// - Returns: A tuple containing the key-value pair previously associated with the `index`.
    ///
    /// - SeeAlso: `canUpdate(_:at:)`
    /// - SeeAlso: `subscript(position:)`
    /// - SeeAlso: `insert(_:at:)`
    @discardableResult
    public mutating func update(
        _ newElement: Element,
        at index: Index
    ) -> Element {
        precondition(
            indices.contains(index),
            "[OrderedDictionary] Index is out of bounds"
        )
        
        defer { _assertInvariant() }
        
        let (newKey, newValue) = newElement
        
        let previousElement = self[index]
        let previousKey = previousElement.key
        
        let isSameKey = previousKey == newKey
        let isExistingKey = containsKey(newKey)

        precondition(
            isSameKey || !isExistingKey,
            "[OrderedDictionary] Index-based update produced duplicate keys"
        )
        
        if (!isSameKey) {
            _keysToValues.removeValue(forKey: previousKey)
        }
        
        _orderedKeys[index] = newKey
        _keysToValues[newKey] = newValue
        
        return previousElement
    }
    
    /// Removes and returns the key-value pair at the specified position if there is any key-value
    /// pair, or `nil` if there is none.
    ///
    /// The following example shows how to remove a key-value pair at a specific index:
    ///
    ///     var orderedDictionary: OrderedDictionary<String, Int> = ["a": 1, "b": 2, "c": 3]
    ///
    ///     let removedElement = orderedDictionary.remove(at: 1)
    ///
    ///     print(removedElement)
    ///     // => Optional((key: "b", value: 2))
    ///
    ///     print(orderedDictionary)
    ///     // => ["a": 1, "c": 3]
    ///
    /// - Parameters:
    ///   - index: The position of the key-value pair to remove.
    /// - Returns: The element at the specified index, or `nil` if the position is not taken.
    ///
    /// - SeeAlso: `subscript(position:)`
    /// - SeeAlso: `removeValue(forKey:)`
    @discardableResult
    public mutating func remove(at index: Index) -> Element? {
        guard let element = elementAt(index) else { return nil }
        
        defer { _assertInvariant() }
        
        _orderedKeys.remove(at: index)
        _keysToValues.removeValue(forKey: element.key)
        
        return element
    }
    
    // ============================================================================ //
    // MARK: - Removing First & Last Elements
    // ============================================================================ //
    
    /// Removes and returns the first key-value pair of the ordered dictionary if it is not empty.
    public mutating func popFirst() -> Element? {
        guard !isEmpty else { return nil }
        return remove(at: startIndex)
    }
    
    /// Removes and returns the last key-value pair of the ordered dictionary if it is not empty.
    public mutating func popLast() -> Element? {
        guard !isEmpty else { return nil }
        return remove(at: index(before: endIndex))
    }
    
    /// Removes and returns the first key-value pair of the ordered dictionary.
    public mutating func removeFirst() -> Element {
        precondition(
            !isEmpty,
            "[OrderedDictionary] Cannot remove key-value pairs when empty"
        )
        
        return remove(at: startIndex)!
    }
    
    /// Removes and returns the last key-value pair of the ordered dictionary.
    public mutating func removeLast() -> Element {
        precondition(
            !isEmpty,
            "[OrderedDictionary] Cannot remove key-value pairs when empty"
        )
        
        return remove(at: index(before: endIndex))!
    }
    
    // ============================================================================ //
    // MARK: - Sorting Elements
    // ============================================================================ //
    
    /// Sorts the ordered dictionary in place, using the given predicate as the comparison between
    /// elements.
    ///
    /// The predicate must be a *strict weak ordering* over the elements.
    ///
    /// - Parameters:
    ///   - areInIncreasingOrder: A predicate that returns `true` if its first argument should
    ///     be ordered before its second argument; otherwise, `false`.
    ///
    /// - SeeAlso: `sorted(by:)`
    public mutating func sort(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows {
        try _sort(
            in: indices,
            by: areInIncreasingOrder
        )
    }
    
    /// Returns a new ordered dictionary, sorted using the given predicate as the comparison
    /// between elements.
    ///
    /// The predicate must be a *strict weak ordering* over the elements.
    ///
    /// The following example shows how to sort an ordered dictionary according the keys or values:
    ///
    ///     let orderedDictionary: OrderedDictionary<String, Int> = ["c": 3, "d": 2, "b": 1, "a": 4]
    ///
    ///     print(orderedDictionary.sorted { $0.key < $1.key })
    ///     // => ["a": 1, "b": 2, "c": 3, "d": 4]
    ///
    ///     print(orderedDictionary.sorted { $0.value < $1.value })
    ///     // => ["b": 1, "d": 2, "c": 3, "a": 4]
    ///
    /// - Parameters:
    ///   - areInIncreasingOrder: A predicate that returns `true` if its first argument should
    ///     be ordered before its second argument; otherwise, `false`.
    /// - Returns: A new ordered dictionary sorted according to the predicate.
    ///
    /// - SeeAlso: `sort(by:)`
    public func sorted(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> Self {
        var new = self
        try new.sort(by: areInIncreasingOrder)
        return new
    }
    
    internal mutating func _sort(
        in range: Range<Index>,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows {
        defer { _assertInvariant() }
        
        try _orderedKeys[range].sort { key1, key2 in
            let element1 = (key: key1, value: _keysToValues[key1]!)
            let element2 = (key: key2, value: _keysToValues[key2]!)
            return try areInIncreasingOrder(element1, element2)
        }
    }
    
    // ============================================================================ //
    // MARK: - Reordering Elements
    // ============================================================================ //
    
    // ------------------------------------------------------- //
    // reverse()
    // ------------------------------------------------------- //
    
    /// Reverses the key-value pairs of the ordered dictionary in place.
    public mutating func reverse() {
        _reverse(in: indices)
    }
    
    internal mutating func _reverse(in range: Range<Index>) {
        defer { _assertInvariant() }
        
        _orderedKeys[range].reverse()
    }
    
    // ------------------------------------------------------- //
    // shuffle(using:)
    // ------------------------------------------------------- //
    
    /// Shuffles the ordered dictionary in place, using the given generator as a source
    /// for randomness.
    public mutating func shuffle<T>(
        using generator: inout T
    ) where T: RandomNumberGenerator {
        _shuffle(in: indices, using: &generator)
    }
    
    public mutating func _shuffle<T>(
        in range: Range<Index>,
        using generator: inout T
    ) where T: RandomNumberGenerator {
        defer { _assertInvariant() }
        
        _orderedKeys[range].shuffle(using: &generator)
    }
    
    // ------------------------------------------------------- //
    // partition(by:)
    // ------------------------------------------------------- //
    
    /// Reorders the key-value pairs of the ordered dictionary such that all the key-value pairs
    /// that match the given predicate are after all the key-value pairs that do not match.
    public mutating func partition(
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index {
        return try _partition(
            in: indices,
            by: belongsInSecondPartition
        )
    }
    
    internal mutating func _partition(
        in range: Range<Index>,
        by belongsInSecondPartition: (Element) throws -> Bool
    ) rethrows -> Index {
        defer { _assertInvariant() }
        
        return try _orderedKeys[range].partition { key in
            let element = (key: key, value: _keysToValues[key]!)
            return try belongsInSecondPartition(element)
        }
    }
    
    // ------------------------------------------------------- //
    // swapAt(_:_:)
    // ------------------------------------------------------- //
    
    /// Exchanges the elements at the specified indices.
    ///
    /// - Parameters:
    ///   - i: The index of the first value to swap.
    ///   - j: The index of the second value to swap.
    ///
    /// - Precondition: Both indices must be valid existing indices of the ordered dictionary.
    /// - Complexity: O(1)
    public mutating func swapAt(_ i: Index, _ j: Index) {
        _orderedKeys.swapAt(i, j)
    }
    
    // ============================================================================ //
    // MARK: - Transformations
    // ============================================================================ //
    
    /// Returns a new ordered dictionary containing the keys of this ordered dictionary with
    /// the values transformed by the given closure while preserving the original order.
    public func mapValues<T>(
        _ transform: (Value) throws -> T
    ) rethrows -> OrderedDictionary<Key, T> {
        var result = OrderedDictionary<Key, T>()
        
        for (key, value) in self {
            result[key] = try transform(value)
        }
        
        return result
    }
    
    /// Returns a new ordered dictionary containing only the key-value pairs that have non-nil
    /// values as the result of transformation by the given closure while preserving the original
    /// order.
    public func compactMapValues<T>(
        _ transform: (Value) throws -> T?
    ) rethrows -> OrderedDictionary<Key, T> {
        var result = OrderedDictionary<Key, T>()
        
        for (key, value) in self {
            if let transformedValue = try transform(value) {
                result[key] = transformedValue
            }
        }
        
        return result
    }
    
    /// Returns a new ordered dictionary container the key-value pairs that satisfy the given
    /// predicate while preserving the original order.
    public func filter(
        _ isIncluded: (Element) throws -> Bool
    ) rethrows -> Self {
        return Self(uniqueKeysWithValues: try self.lazy.filter(isIncluded))
    }
    
    // ============================================================================ //
    // MARK: - Capacity
    // ============================================================================ //

    /// The total number of elements that the ordered dictionary can contain without allocating
    /// new storage.
    public var capacity: Int {
        return Swift.min(_orderedKeys.capacity, _keysToValues.capacity)
    }

    /// Reserves enough space to store the specified number of elements, when appropriate
    /// for the underlying types.
    ///
    /// If you are adding a known number of elements to an ordered dictionary, use this method
    /// to avoid multiple reallocations. This method ensures that the underlying types of the
    /// ordered dictionary have space allocated for at least the requested number of elements.
    ///
    /// - Parameters:
    ///   - minimumCapacity: The requested number of elements to store.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        defer { _assertInvariant() }
        
        _orderedKeys.reserveCapacity(minimumCapacity)
        _keysToValues.reserveCapacity(minimumCapacity)
    }
    
    // ============================================================================ //
    // MARK: - Invariant
    // ============================================================================ //
    
    /// Asserts whether the internal invariant is met and traps in the debug mode otherwise.
    /// Inspired by the implementation in PenguinStructures: https://bit.ly/3dDLidO
    ///
    /// - Complexity: O(`count`)
    private func _assertInvariant() {
        assert(
            _computeInvariant(),
            """
            [OrderedDictionary] Broken internal invariant:
             orderedKeys(count: \(_orderedKeys.count)) = \(_orderedKeys)
             keysToValues(count: \(_keysToValues.count)) = \(_keysToValues)
            """
        )
    }
    
    /// Computes the internal invariant for the count and key presence in the underlying storage,
    /// and returns `true` if the invariant is met.
    private func _computeInvariant() -> Bool {
        if _orderedKeys.count != _keysToValues.count { return false }
        
        for index in _orderedKeys.indices {
            let key = _orderedKeys[index]
            if _keysToValues[key] == nil { return false }
        }
        
        return true
    }
    
    // ============================================================================ //
    // MARK: - Internal Storage
    // ============================================================================ //
    
    /// The backing storage for the ordered keys.
    private var _orderedKeys: [Key]
    
    /// The backing storage for the mapping of keys to values.
    private var _keysToValues: [Key: Value]
    
}

extension OrderedDictionary: Hashable where Value: Hashable {}
extension OrderedDictionary: Equatable where Value: Equatable {}

extension OrderedDictionary: ExpressibleByArrayLiteral {
    
    /// Initializes an ordered dictionary initialized from an array literal containing a list
    /// of key-value pairs. Every key in `elements` must be unique.
    public init(arrayLiteral elements: Element...) {
        self.init(uniqueKeysWithValues: elements)
    }
    
}

extension OrderedDictionary: ExpressibleByDictionaryLiteral {
    
    /// Initializes an ordered dictionary initialized from a dictionary literal. Every key
    /// in `elements` must be unique.
    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.init(uniqueKeysWithValues: elements.map { element in
            let (key, value) = element
            return (key: key, value: value)
        })
    }
    
}

extension Array {
    
    /// Initializes an empty array with preallocated space for at least the specified number
    /// of elements.
    fileprivate init(minimumCapacity: Int) {
        self.init()
        self.reserveCapacity(minimumCapacity)
    }
    
}
