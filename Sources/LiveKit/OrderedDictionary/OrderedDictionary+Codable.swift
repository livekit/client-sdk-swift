extension OrderedDictionary: Encodable where Key: Encodable, Value: Encodable {
    
    /// Encodes the contents of this ordered dictionary into the given encoder.
    public func encode(to encoder: Encoder) throws {
        // Encode the ordered dictionary as an array of alternating key-value pairs.
        var container = encoder.unkeyedContainer()
        
        for (key, value) in self {
            try container.encode(key)
            try container.encode(value)
        }
    }
    
}

extension OrderedDictionary: Decodable where Key: Decodable, Value: Decodable {
    
    /// Creates a new ordered dictionary by decoding from the given decoder.
    public init(from decoder: Decoder) throws {
        // Decode the ordered dictionary from an array of alternating key-value pairs.
        self.init()
    
        var container = try decoder.unkeyedContainer()
        
        while !container.isAtEnd {
            let key = try container.decode(Key.self)
            guard !container.isAtEnd else { throw DecodingError.unkeyedContainerReachedEndBeforeValue(decoder.codingPath) }
            let value = try container.decode(Value.self)
            
            self[key] = value
        }
    }
    
}

extension DecodingError {
    
    fileprivate static func unkeyedContainerReachedEndBeforeValue(
        _ codingPath: [CodingKey]
    ) -> DecodingError {
        return DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container reached end before value in key-value pair."
            )
        )
    }
    
}
