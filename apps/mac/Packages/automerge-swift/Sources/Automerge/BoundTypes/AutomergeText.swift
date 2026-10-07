import Foundation

public final class AutomergeText: Codable, @unchecked Sendable {
    var doc: Document?
    var objId: ObjId?
    var _hashOfCurrentValue: Int
    #if canImport(Combine)
    var observerHandle: AnyCancellable?
    #endif
    var _unboundStorage: String

    #if !os(WASI)
    fileprivate let queue = DispatchQueue(label: "automergetext-sync-queue", qos: .userInteractive)
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try queue.sync(execute: work)
    }
    #else
    fileprivate func sync<T>(execute work: () throws -> T) rethrows -> T {
        try work()
    }
    #endif

    public init(_ initialValue: String = "") {
        _unboundStorage = initialValue
        _hashOfCurrentValue = initialValue.hashValue
    }

    public convenience init(_ initialValue: String = "", doc: Document, path: String) throws {
        self.init(initialValue)
        let codingPath = try AnyCodingKey.parsePath(path)
        if codingPath.isEmpty {
            throw BindingError.InvalidPath("Path can't be empty to bind an instance of AutomergeText")
        }
        if codingPath.count == 1 {

            if codingPath[0].intValue != nil {
                throw BindingError
                    .InvalidPath("First path element in an Automerge document can't be an index position.")
            }
            let textObjId = try doc.putObject(obj: ObjId.ROOT, key: codingPath[0].stringValue, ty: .Text)
            self.doc = doc
            objId = textObjId
        } else {
            guard let lastPathElement = codingPath.last else {
                throw BindingError.InvalidPath("Unable to request a final path element from path \(path)")
            }
            let result = doc.retrieveObjectId(
                path: codingPath,
                containerType: .Value,
                strategy: .createWhenNeeded
            )
            switch result {
            case let .success(secondToLastPathItemObjId):
                if let indexLocation = lastPathElement.intValue {
                    let textObjId = try doc.putObject(
                        obj: secondToLastPathItemObjId,
                        index: UInt64(indexLocation),
                        ty: .Text
                    )
                    self.doc = doc
                    objId = textObjId
                } else {
                    let textObjId = try doc.putObject(
                        obj: secondToLastPathItemObjId,
                        key: lastPathElement.stringValue,
                        ty: .Text
                    )
                    self.doc = doc
                    objId = textObjId
                }
            case let .failure(failure):
                throw failure
            }
        }
        try updateText(newText: initialValue)
        observeDocForChanges()
    }

    public convenience init(doc: Document, objId: ObjId) throws {
        self.init()
        if doc.objectType(obj: objId) == .Text {
            sync {
                self.doc = doc
                self.objId = objId
            }
        } else {
            throw BindingError.NotText
        }
        observeDocForChanges()
    }

    deinit {
        #if canImport(Combine)
        observerHandle?.cancel()
        #endif
    }

    public var isBound: Bool {
        sync { doc != nil && objId != nil }
    }

    public func bind(doc: Document, path: String) throws {
        assert(self.doc == nil && objId == nil)
        let codingPath = try AnyCodingKey.parsePath(path)
        if codingPath.isEmpty {
            throw BindingError.InvalidPath("Path can't be empty to bind an instance of AutomergeText")
        }
        if codingPath.count == 1 {

            if codingPath[0].intValue != nil {
                throw BindingError
                    .InvalidPath("First path element in an Automerge document can't be an index position.")
            }
            let textObjId = try doc.putObject(obj: ObjId.ROOT, key: codingPath[0].stringValue, ty: .Text)
            sync {
                self.doc = doc
                objId = textObjId
            }
        } else {
            guard let lastPathElement = codingPath.last else {
                throw BindingError.InvalidPath("Unable to request a final path element from path \(path)")
            }
            let result = doc.retrieveObjectId(
                path: codingPath,
                containerType: .Value,
                strategy: .createWhenNeeded
            )
            switch result {
            case let .success(secondToLastPathItemObjId):
                if let indexLocation = lastPathElement.intValue {
                    let textObjId = try doc.putObject(
                        obj: secondToLastPathItemObjId,
                        index: UInt64(indexLocation),
                        ty: .Text
                    )
                    sync {
                        self.doc = doc
                        objId = textObjId
                    }
                } else {
                    let textObjId = try doc.putObject(
                        obj: secondToLastPathItemObjId,
                        key: lastPathElement.stringValue,
                        ty: .Text
                    )
                    sync {
                        self.doc = doc
                        objId = textObjId
                    }
                }
            case let .failure(failure):
                throw failure
            }
        }
        if !_unboundStorage.isEmpty {
            try updateText(newText: _unboundStorage)
            sync {
                _unboundStorage = ""
            }
        }
        observeDocForChanges()
    }

    public func bind(doc: Document, id: ObjId) throws {

        if doc.objectType(obj: id) == .Text {
            sync {
                self.doc = doc
                objId = id
            }
        } else {
            throw BindingError.NotText
        }
        if !_unboundStorage.isEmpty {
            try updateText(newText: _unboundStorage)
            sync {
                _unboundStorage = ""
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
                guard let self = self, let objId = self.objId else {
                    return
                }

                Task {
                    let valueFromDoc = try doc.text(obj: objId)
                    let hashOfCurrentValue = self.sync { self._hashOfCurrentValue }
                    if valueFromDoc.hashValue != hashOfCurrentValue {
                        self.sendObjectWillChange()
                    }
                }
            })
        }
        #endif
    }

    public var value: String {
        get {
            sync {
                guard let doc, let objId else {
                    return _unboundStorage
                }
                do {
                    let content = try doc.text(obj: objId)
                    if content.hashValue != self._hashOfCurrentValue {
                        self._hashOfCurrentValue = content.hashValue
                    }
                    return content
                } catch {
                    fatalError("Error attempting to read text value from objectId \(objId): \(error)")
                }
            }
        }
        set {
            guard let objId, doc != nil else {
                sync {
                    _unboundStorage = newValue
                }
                return
            }
            do {
                try updateText(newText: newValue)
            } catch {
                fatalError("Error attempting to write '\(newValue)' to objectId \(objId): \(error)")
            }
        }
    }

    private func updateText(newText: String) throws {
        guard let objId, let doc else {
            throw BindingError.Unbound
        }
        let current = try doc.text(obj: objId)
        if current != newText {
            sync {
                _hashOfCurrentValue = newText.hashValue
            }
            try doc.updateText(obj: objId, value: newText)
        }
    }

    public enum CodingKeys: String, CodingKey {
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _unboundStorage = try container.decode(String.self, forKey: .value)
        _hashOfCurrentValue = _unboundStorage.hashValue
    }
}

extension AutomergeText: Equatable {
    public static func == (lhs: AutomergeText, rhs: AutomergeText) -> Bool {
        if lhs.objId != nil, rhs.objId != nil {
            return lhs.objId == rhs.objId
        } else {
            return lhs.value == rhs.value
        }
    }
}

extension AutomergeText: Hashable {
    public func hash(into hasher: inout Hasher) {
        sync {
            hasher.combine(objId)
            hasher.combine(_unboundStorage)
        }
    }
}

extension AutomergeText: CustomStringConvertible {
    public var description: String {
        value
    }
}

extension AutomergeText: CustomDebugStringConvertible {
    public var debugDescription: String {
        guard let doc, let objId else {
            return "AutomergeText(unbound): \(_unboundStorage)"
        }
        do {
            let path = try doc.path(obj: objId).stringPath()
            return "AutomergeText(\(path)): \(value)"
        } catch {
            return "AutomergeText(\(objId.debugDescription)): \(value)"
        }
    }
}

#if canImport(Combine)

import Combine
#if canImport(os)
import os
#endif

extension AutomergeText: ObservableObject {
    fileprivate func sendObjectWillChange() {

        objectWillChange.send()
    }
}
#else
fileprivate extension AutomergeText {
    func sendObjectWillChange() {}
}
#endif

#if canImport(SwiftUI)
import struct SwiftUI.Binding

public extension AutomergeText {

    func textBinding() -> Binding<String> {
        Binding(
            get: { () -> String in
                guard let doc = self.doc, let objId = self.objId else {
                    return self.sync { self._unboundStorage }
                }
                do {
                    let content = try doc.text(obj: objId)
                    if content.hashValue != self._hashOfCurrentValue {
                        self._hashOfCurrentValue = content.hashValue
                    }
                    return content
                } catch {
                    fatalError("Error attempting to read text value from objectId \(objId): \(error)")
                }
            },
            set: { (newValue: String) in
                guard let objId = self.objId, self.doc != nil else {
                    self.sync {
                        self._unboundStorage = newValue
                        self._hashOfCurrentValue = newValue.hashValue
                    }
                    return
                }
                do {
                    if newValue.hashValue != self._hashOfCurrentValue {
                        try self.updateText(newText: newValue)
                    }
                } catch {
                    fatalError("Error attempting to write '\(newValue)' to objectId \(objId): \(error)")
                }
            }
        )
    }
}
#endif
