public struct AutomergeEncoder {

    public var userInfo: [CodingUserInfoKey: Any] = [:]

    public let doc: Document

    public var schemaStrategy: SchemaStrategy

    public var cautiousWrite: Bool

    public let logLevel: LogVerbosity

    public init(
        doc: Document,
        strategy: SchemaStrategy = .createWhenNeeded,
        cautiousWrite: Bool = false,
        reportingLoglevel: LogVerbosity = .errorOnly
    ) {
        self.doc = doc
        schemaStrategy = strategy
        self.cautiousWrite = cautiousWrite
        logLevel = reportingLoglevel
    }

    public func encode<T: Encodable>(_ value: T?) throws {

        if let definiteValue = value {
            try encode(definiteValue)
        }
    }

    public func encode<T: Encodable>(_ value: T) throws {
        let encoder = AutomergeEncoderImpl(
            userInfo: userInfo,
            codingPath: [],
            doc: doc,
            strategy: schemaStrategy,
            cautiousWrite: cautiousWrite,
            logLevel: logLevel
        )
        switch value {

        case let value as AutomergeText:
            var container = encoder.container(keyedBy: AutomergeText.CodingKeys.self)
            try container.encode(value, forKey: .value)
        default:
            try value.encode(to: encoder)
        }
        encoder.postencodeCleanup()
    }

    public func encode<T: Encodable>(_ value: T, at path: [CodingKey]) throws {
        let encoder = AutomergeEncoderImpl(
            userInfo: userInfo,
            codingPath: path,
            doc: doc,
            strategy: schemaStrategy,
            cautiousWrite: cautiousWrite,
            logLevel: logLevel
        )
        switch value {

        case let value as AutomergeText:
            var container = encoder.container(keyedBy: AutomergeText.CodingKeys.self)
            try container.encode(value, forKey: .value)
        default:
            try value.encode(to: encoder)
        }
        encoder.postencodeCleanup(below: path.map { AnyCodingKey($0) })
    }
}
