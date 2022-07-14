extension OrderedDictionary {
    
    // ============================================================================ //
    // MARK: - Initialization
    // ============================================================================ //
    
    @available(*, deprecated, message: "Please use init(values:uniquelyKeyedBy:).", renamed: "init(values:uniquelyKeyedBy:)")
    public init<S: Sequence>(
        values: S,
        keyedBy extractKey: (Value) -> Key
    ) where S.Element == Value {
        self.init(values: values, uniquelyKeyedBy: extractKey)
    }
    
    @available(*, deprecated, message: "Please use init(values:uniquelyKeyedBy:).", renamed: "init(values:uniquelyKeyedBy:)")
    public init(
        values: [Value],
        keyedBy keyPath: KeyPath<Value, Key>
    ) {
        self.init(values: values, uniquelyKeyedBy: keyPath)
    }
    
    @available(*, deprecated, message: "Please use init(uniqueKeysWithValues:).", renamed: "init(uniqueKeysWithValues:)")
    public init<S: Sequence>(_ elements: S) where S.Element == Element {
        self.init(uniqueKeysWithValues: elements)
    }
    
    // ============================================================================ //
    // MARK: - Insertion Checks
    // ============================================================================ //
    
    /// Checks whether the given key-value pair can be inserted into to ordered dictionary
    /// by validating the presence of the key.
    ///
    /// - Parameters:
    ///   - newElement: The key-value pair to be inserted into the ordered dictionary.
    /// - Returns: `true` if the key-value pair can be safely inserted; otherwise, `false`.
    ///
    /// - SeeAlso: `canInsert(key:)`
    /// - SeeAlso: `canInsert(at:)`
    @available(*, deprecated, message: "Use canInsert(key:) with the element's key instead.")
    public func canInsert(_ newElement: Element) -> Bool {
        return canInsert(key: newElement.key)
    }
    
    // ============================================================================ //
    // MARK: - Moving Elements
    // ============================================================================ //
    
    /// Moves an existing key-value pair specified by the given key to the new index by removing
    /// it from its original index first and inserting it at the new index. If the movement is
    /// actually performed, the previous index of the key-value pair is returned. Otherwise, `nil`
    /// is returned.
    ///
    /// - Parameters:
    ///   - key: The key specifying the key-value pair to move.
    ///   - newIndex: The new index the key-value pair should be moved to.
    /// - Returns: The previous index of the key-value pair if it was sucessfully moved.
    @available(*, deprecated, message: "Since the concrete behavior of the element movement highly depends on concrete use cases, its official support will be dropped in the future. Please use the public API for modeling a move operation instead.")
    @discardableResult
    public mutating func moveElement(forKey key: Key, to newIndex: Index) -> Index? {
        // Load the previous index and return nil if the index is not found.
        guard let previousIndex = index(forKey: key) else { return nil }
        
        // If the previous and new indices match, treat it as if the movement was already
        // performed.
        guard previousIndex != newIndex else { return previousIndex }
        
        // Remove the value for the key at its original index.
        let value = removeValue(forKey: key)!
        
        // Validate the new index.
        precondition(canInsert(at: newIndex), "Cannot move to invalid index in OrderedDictionary")

        // Insert the element at the new index.
        insert((key: key, value: value), at: newIndex)
        
        return previousIndex
    }
    
}
