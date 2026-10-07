import Foundation
#if canImport(os)
import os 
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers

@available(macOS 11.0, iOS 14.0, *)
public extension UTType {

    static var automerge: UTType {
        UTType(importedAs: "com.github.automerge", conformingTo: UTType.data)
    }
}

#if canImport(CoreTransferable)
import CoreTransferable

@available(macOS 13.0, iOS 16.0, *)
extension Document: Transferable {

    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .automerge) { document in
            document.save()
        } importing: { data in
            do {
                return try Document(data)
            } catch {
                #if canImport(os)
                Logger(subsystem: "Automerge", category: "Document")
                    .error("Error decoding transfered Automerge data: \(error, privacy: .public)")
                #endif
                return Document()
            }
        }
    }
}
#endif

#endif
