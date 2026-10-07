#if canImport(os)
import os
#endif

final class AutomergeEncoderImpl {
    let userInfo: [CodingUserInfoKey: Any]
    let codingPath: [CodingKey]
    let document: Document
    let schemaStrategy: SchemaStrategy
    let cautiousWrite: Bool
    let reportingLogLevel: LogVerbosity

    var singleValueWritten: Bool = false

    var containerType: EncodingContainerType?
    var childEncoders: [AutomergeEncoderImpl] = []
    var highestUnkeyedIndexWritten: UInt64?
    var mapKeysWritten: [String] = []
    var objectIdForContainer: ObjId?

    init(
        userInfo: [CodingUserInfoKey: Any],
        codingPath: [CodingKey],
        doc: Document,
        strategy: SchemaStrategy,
        cautiousWrite: Bool,
        logLevel: LogVerbosity
    ) {
        self.userInfo = userInfo
        self.codingPath = codingPath
        document = doc
        schemaStrategy = strategy
        self.cautiousWrite = cautiousWrite
        reportingLogLevel = logLevel
    }

    func postencodeCleanup(below prefix: [AnyCodingKey] = []) {
        precondition(objectIdForContainer != nil)
        precondition(containerType != nil)
        guard let objectIdForContainer, let containerType else {
            return
        }
        if codingPath.map({ AnyCodingKey($0) }).starts(with: prefix) {
            switch containerType {
            case .Key:

                let extraAutomergeKeys = document.keys(obj: objectIdForContainer)
                    .filter { keyValue in
                        !mapKeysWritten.contains(keyValue)
                    }
                for extraKey in extraAutomergeKeys {
                    do {
                        try document.delete(obj: objectIdForContainer, key: extraKey)
                    } catch {
                        fatalError("Unable to delete extra key \(extraKey) during post-encode cleanup: \(error)")
                    }
                }
            case .Index:
                var highestIndexWritten: Int64 = -1
                if let highestUnkeyedIndexWritten {

                    highestIndexWritten = Int64(highestUnkeyedIndexWritten)
                }
                let lengthOfAutomergeContainer = document.length(obj: objectIdForContainer)
                if lengthOfAutomergeContainer > 0 {
                    var highestAutomergeIndex = Int64(lengthOfAutomergeContainer - 1)

                    while highestAutomergeIndex > highestIndexWritten {
                        do {
                            try document.delete(obj: objectIdForContainer, index: UInt64(highestAutomergeIndex))
                            highestAutomergeIndex -= 1
                        } catch {
                            fatalError(
                                "Unable to delete index position \(highestAutomergeIndex) during post-encode cleanup: \(error)"
                            )
                        }
                    }
                }
            case .Value:

                return
            }
        }

        for child in childEncoders {
            child.postencodeCleanup()
        }
    }
}

extension AutomergeEncoderImpl: Encoder {

    func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
        guard singleValueWritten == false else {
            preconditionFailure()
        }

        let container = AutomergeKeyedEncodingContainer<Key>(
            impl: self,
            codingPath: codingPath,
            doc: document
        )
        containerType = .Key
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        guard singleValueWritten == false else {
            preconditionFailure()
        }

        containerType = .Index
        return AutomergeUnkeyedEncodingContainer(
            impl: self,
            codingPath: codingPath,
            doc: document
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        guard singleValueWritten == false else {
            preconditionFailure()
        }

        containerType = .Value
        return AutomergeSingleValueEncodingContainer(
            impl: self,
            codingPath: codingPath,
            doc: document
        )
    }
}
