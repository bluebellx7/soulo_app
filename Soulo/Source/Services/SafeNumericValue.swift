import CoreFoundation
import Foundation

enum SafeNumericValue {
    // A single page report is a delta, not a lifetime total.
    static let maximumEventCount = 1_000_000

    static func nonnegativeInt64(_ value: Any?) -> Int64? {
        let integer: Int64?
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            integer = Int64(number.stringValue) ?? Int64(exactly: number.doubleValue)
        } else if let string = value as? String, string.count <= 32 {
            integer = Int64(string)
        } else {
            return nil
        }
        guard let integer, integer >= 0 else { return nil }
        return integer
    }

    static func nonnegativeInt(_ value: Any?) -> Int? {
        nonnegativeInt64(value).flatMap { Int(exactly: $0) }
    }

    static func eventCount(_ value: Any?) -> Int? {
        guard let count = nonnegativeInt(value), (1...maximumEventCount).contains(count) else { return nil }
        return count
    }

    static func addingCounts(_ first: Int, _ second: Int) -> Int {
        let sum = max(0, first).addingReportingOverflow(max(0, second))
        return sum.overflow ? .max : sum.partialValue
    }

    static func totalCount<S: Sequence>(_ counts: S) -> Int where S.Element == Int {
        counts.reduce(0, addingCounts)
    }

    /// Nil means an unknown/invalid total, never a wrapped byte count.
    static func byteCountTotal(_ counts: [Int64], requirePositive: Bool = false) -> Int64? {
        guard !counts.isEmpty else { return nil }
        var total: Int64 = 0
        for count in counts {
            guard requirePositive ? count > 0 : count >= 0 else { return nil }
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}
