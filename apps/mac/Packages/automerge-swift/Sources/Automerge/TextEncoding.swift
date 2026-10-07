import enum AutomergeUniffi.TextEncoding
import Foundation

public enum TextEncoding {

    case graphemeCluster

    case unicodeScalar

    case utf8

    case utf16
}

typealias FfiTextEncoding = AutomergeUniffi.TextEncoding

extension FfiTextEncoding {
    var textEncoding: TextEncoding {
        switch self {
        case .graphemeCluster: return .graphemeCluster
        case .unicodeCodePoint: return .unicodeScalar
        case .utf16CodeUnit: return .utf16
        case .utf8CodeUnit: return .utf8
        }
    }
}

extension TextEncoding {
    var ffi_textEncoding: FfiTextEncoding {
        switch self {
        case .graphemeCluster: return .graphemeCluster
        case .unicodeScalar: return .unicodeCodePoint
        case .utf16: return .utf16CodeUnit
        case .utf8: return .utf8CodeUnit
        }
    }
}
