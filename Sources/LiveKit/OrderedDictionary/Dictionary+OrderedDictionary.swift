extension Dictionary {
    
    /// Returns an ordered dictionary containing the key-value pairs from the dictionary, sorted
    /// using the given sort function.
    ///
    /// - Parameters:
    ///   - areInIncreasingOrder: The sort function which compares the key-value pairs.
    /// - Returns: The ordered dictionary.
    ///
    /// - SeeAlso: `OrderedDictionary.init(unsorted:areInIncreasingOrder:)`
    public func sorted(
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> OrderedDictionary<Key, Value> {
        return try OrderedDictionary(
            unsorted: self,
            areInIncreasingOrder: areInIncreasingOrder
        )
    }
    
}
