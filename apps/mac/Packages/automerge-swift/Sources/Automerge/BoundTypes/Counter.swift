import Foundation

public final class Counter: Codable, @unchecked Sendable {
    var doc: Document?
    var objId: ObjId?
    var codingkey: AnyCodingKey?
    var _hashOfCurrentValue: Int
    #if canImport(Combine)
    var observerHandle: AnyCancellable?
    #endif
    var _unboundStorage: Int

    #if !os(WASI)
    fileprivate let queue = DispatchQueue(label: "automergecounter-sync-queue", qos: .userInteractive)
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }
    #else
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try work()
    }
    #endif

    public init(_ initialValue: Int = 0) {
        _unboundStorage = initialValue
        _hashOfCurrentValue = initialValue.hashValue
    }

    public convenience init(_ initialValue: Int = 0, doc: Document, path: String) throws {
        self.init(initialValue)
        try bind(doc: doc, path: path)
    }

    public convenience init(doc: Document, objId: ObjId, key: any CodingKey) throws {
        self.init()

        if let index = key.intValue {
            if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, index: UInt64(index)) {
                sync {
                    self.doc = doc
                    self.objId = objId
                    codingkey = AnyCodingKey(key)
                    _hashOfCurrentValue = counterValue.hashValue
                }
            } else {
                throw BindingError.NotCounter
            }
        } else {
            if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, key: key.stringValue) {
                sync {
                    self.doc = doc
                    self.objId = objId
                    codingkey = AnyCodingKey(key)
                    _hashOfCurrentValue = counterValue.hashValue
                }
            } else {
                throw BindingError.NotCounter
            }
        }
        observeDocForChanges()
    }

    deinit {
        #if canImport(Combine)
        observerHandle?.cancel()
        #endif
    }

    public var isBound: Bool {
        sync {
            doc != nil && objId != nil
        }
    }

    public func bind(doc: Document, path: String) throws {
        let objId: ObjId
        let codingPath = try AnyCodingKey.parsePath(path)
        let lookupResult = doc.retrieveObjectId(path: codingPath, containerType: .Value, strategy: .readonly)
        switch lookupResult {
        case let .success(success):
            objId = success
        case let .failure(failure):
            throw failure
        }
        guard let key = codingPath.last else {
            throw BindingError.InvalidPath(path)
        }
        if let index = key.intValue {
            if case .Scalar(.Counter) = try doc.get(obj: objId, index: UInt64(index)) {
                sync {
                    self.doc = doc
                    self.objId = objId
                    codingkey = key
                }
                let currentUnboundValue = sync { self._unboundStorage }
                if currentUnboundValue != 0 {

                    try doc.increment(obj: objId, index: UInt64(index), by: Int64(_unboundStorage))
                    sync {
                        _unboundStorage = 0
                    }
                }
            } else {
                throw BindingError.NotCounter
            }
        } else {
            if case .Scalar(.Counter) = try doc.get(obj: objId, key: key.stringValue) {
                sync {
                    self.doc = doc
                    self.objId = objId
                    codingkey = key
                }
                let currentUnboundValue = sync { self._unboundStorage }
                if currentUnboundValue != 0 {

                    try doc.increment(obj: objId, key: key.stringValue, by: Int64(_unboundStorage))
                    sync {
                        _unboundStorage = 0
                    }
                }
            } else {
                throw BindingError.NotCounter
            }
        }
        observeDocForChanges()
    }

    private func observeDocForChanges() {
        #if canImport(Combine)
        guard let doc = doc else {
            return
        }

        if observerHandle == nil {
            observerHandle = doc.objectWillChange.sink(receiveValue: { [weak self] _ in
                guard let self else {
                    return
                }

                let _hashOfCurrentValue = sync { self._hashOfCurrentValue }
                Task {
                    let currentValue = self.getCounterValue()
                    if currentValue.hashValue != _hashOfCurrentValue {
                        self.sendObjectWillChange()
                    }
                }
            })
        }
        #endif
    }

    public var value: Int {
        get {
            getCounterValue()
        }
        set {
            setCounterValue(newValue)
        }
    }

    fileprivate func getCounterValue() -> Int {
        guard let doc, let objId, let codingkey else {
            return sync {
                _unboundStorage
            }
        }
        do {
            if let index = codingkey.intValue {
                if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, index: UInt64(index)) {
                    let converted = Int(counterValue)
                    if _hashOfCurrentValue != converted.hashValue {
                        _hashOfCurrentValue = converted.hashValue
                    }
                    return converted
                }
            } else {
                if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, key: codingkey.stringValue) {
                    let converted = Int(counterValue)
                    if _hashOfCurrentValue != converted.hashValue {
                        _hashOfCurrentValue = converted.hashValue
                    }
                    return converted
                }
            }
        } catch {
            fatalError("Error attempting to read text value from objectId \(objId): \(error)")
        }
        fatalError()
    }

    fileprivate func setCounterValue(_ intValue: Int) {
        _hashOfCurrentValue = sync { intValue.hashValue }
        guard let objId, let doc, let codingkey else {
            sync { _unboundStorage = intValue }
            return
        }
        do {
            if let index = codingkey.intValue {
                if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, index: UInt64(index)) {
                    let bindingDifference = Int64(intValue) - counterValue
                    try doc.increment(obj: objId, index: UInt64(index), by: bindingDifference)
                    if _hashOfCurrentValue != counterValue.hashValue {
                        _hashOfCurrentValue = counterValue.hashValue
                    }
                } else {
                    throw BindingError.NotCounter
                }
            } else {
                if case let .Scalar(.Counter(counterValue)) = try doc.get(obj: objId, key: codingkey.stringValue) {
                    let bindingDifference = Int64(intValue) - counterValue
                    try doc.increment(obj: objId, key: codingkey.stringValue, by: bindingDifference)
                    if _hashOfCurrentValue != counterValue.hashValue {
                        _hashOfCurrentValue = counterValue.hashValue
                    }
                } else {
                    throw BindingError.NotCounter
                }
            }
        } catch {
            fatalError("Error attempting to write '\(intValue)' to objectId \(objId): \(error)")
        }
    }

    public func increment(by value: Int) {
        guard let objId, let doc, let codingkey else {
            sync {
                _unboundStorage += value
                _hashOfCurrentValue = _unboundStorage.hashValue
            }
            return
        }
        do {
            if let index = codingkey.intValue {
                if case let .Scalar(.Counter(currentValue)) = try doc.get(obj: objId, index: UInt64(index)) {
                    try doc.increment(obj: objId, index: UInt64(index), by: Int64(value))
                    sync {
                        _hashOfCurrentValue = (Int(currentValue) + value).hashValue
                    }
                } else {
                    throw BindingError.NotCounter
                }
            } else {
                if case let .Scalar(.Counter(currentValue)) = try doc.get(obj: objId, key: codingkey.stringValue) {
                    try doc.increment(obj: objId, key: codingkey.stringValue, by: Int64(value))
                    sync {
                        _hashOfCurrentValue = (Int(currentValue) + value).hashValue
                    }
                } else {
                    throw BindingError.NotCounter
                }
            }
        } catch {
            fatalError(
                "Error attempting to increment counter by '\(value)' to objectId \(objId) key \(codingkey): \(error)"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _unboundStorage = try container.decode(Int.self, forKey: .value)
        _hashOfCurrentValue = _unboundStorage.hashValue
    }
}

extension Counter: Equatable {

    public static func == (lhs: Counter, rhs: Counter) -> Bool {
        if lhs.objId != nil, rhs.objId != nil {
            return lhs.objId == rhs.objId
        } else {
            return lhs.value == rhs.value
        }
    }
}

extension Counter: Hashable {
    public func hash(into hasher: inout Hasher) {
        sync {
            hasher.combine(objId)
            hasher.combine(value)
        }
    }
}

extension Counter: CustomStringConvertible {

    public var description: String {
        String(value)
    }
}

#if canImport(Combine)
import Combine

extension Counter: ObservableObject {
    fileprivate func sendObjectWillChange() {
        objectWillChange.send()
    }
}
#else
fileprivate extension Counter {
    func sendObjectWillChange() {}
}
#endif

#if canImport(SwiftUI)
import struct SwiftUI.Binding

public extension Counter {

    func valueBinding() -> Binding<Int> {
        Binding(
            get: { () -> Int in
                let valueToReturn = self.getCounterValue()
                if self._hashOfCurrentValue != valueToReturn.hashValue {
                    self._hashOfCurrentValue = valueToReturn.hashValue
                }
                return valueToReturn
            },
            set: { (newValue: Int) in
                if newValue.hashValue != self._hashOfCurrentValue {
                    self.setCounterValue(newValue)
                }
            }
        )
    }
}
#endif
