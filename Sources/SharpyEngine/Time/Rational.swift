// Exact rational arithmetic. Time in Sharpy is never a Double: a frame at 29.97 fps is
// 1001/30000 s exactly, and every anchor, cut and assertion resolves through this type.
// Overflow is a programming error, not a rounding event, so it traps.

public struct Rational: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    /// Numerator. Sign of the value lives here.
    public let num: Int64
    /// Denominator, always > 0. The pair is always in lowest terms.
    public let den: Int64

    public init(_ num: Int64, _ den: Int64) {
        precondition(den != 0, "Rational with zero denominator")
        let sign: Int64 = den < 0 ? -1 : 1
        let g = Rational.gcd(num.magnitude, den.magnitude)
        let d = Int64(g == 0 ? 1 : g)
        self.num = sign * num / d
        self.den = sign * den / d
    }

    public init(_ integer: Int64) { self.init(integer, 1) }

    public static let zero = Rational(0, 1)
    public static let one = Rational(1, 1)

    public var isZero: Bool { num == 0 }
    public var isNegative: Bool { num < 0 }

    /// Floor division to an integer.
    public var floor: Int64 {
        let q = num / den
        return (num % den != 0 && num < 0) ? q - 1 : q
    }

    public var ceil: Int64 {
        let q = num / den
        return (num % den != 0 && num > 0) ? q + 1 : q
    }

    /// Round half away from zero.
    public var rounded: Int64 {
        let twice = Rational(2 * num, den)
        let r = twice.num.magnitude / twice.den.magnitude
        let mag = Int64((r + 1) / 2)
        return num < 0 ? -mag : mag
    }

    /// Double approximation — for display and for handing to APIs that only take doubles.
    /// Never feed this back into time arithmetic.
    public var doubleValue: Double { Double(num) / Double(den) }

    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    // MARK: arithmetic (trapping on overflow)

    public static func + (a: Rational, b: Rational) -> Rational {
        if a.den == b.den { return Rational(checkedAdd(a.num, b.num), a.den) }
        let l = lcm(a.den, b.den)
        return Rational(checkedAdd(checkedMul(a.num, l / a.den), checkedMul(b.num, l / b.den)), l)
    }

    public static prefix func - (a: Rational) -> Rational { Rational(-a.num, a.den) }
    public static func - (a: Rational, b: Rational) -> Rational { a + (-b) }

    public static func * (a: Rational, b: Rational) -> Rational {
        // cross-reduce first to keep intermediates small
        let g1 = Int64(gcd(a.num.magnitude, b.den.magnitude))
        let g2 = Int64(gcd(b.num.magnitude, a.den.magnitude))
        let n1 = g1 == 0 ? a.num : a.num / g1
        let d2 = g1 == 0 ? b.den : b.den / g1
        let n2 = g2 == 0 ? b.num : b.num / g2
        let d1 = g2 == 0 ? a.den : a.den / g2
        return Rational(checkedMul(n1, n2), checkedMul(d1, d2))
    }

    public static func / (a: Rational, b: Rational) -> Rational {
        precondition(!b.isZero, "Rational division by zero")
        return a * Rational(b.den, b.num)
    }

    public static func < (a: Rational, b: Rational) -> Bool {
        // compare a.num * b.den < b.num * a.den without overflow where possible
        let (l, lo) = a.num.multipliedReportingOverflow(by: b.den)
        let (r, ro) = b.num.multipliedReportingOverflow(by: a.den)
        if !lo && !ro { return l < r }
        return a.doubleValue < b.doubleValue  // astronomically large values only
    }

    // MARK: helpers

    @inline(__always) static func gcd(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    static func lcm(_ a: Int64, _ b: Int64) -> Int64 {
        let g = Int64(gcd(a.magnitude, b.magnitude))
        return checkedMul(a / g, b)
    }

    @inline(__always) static func checkedAdd(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        precondition(!o, "Rational overflow in add")
        return r
    }

    @inline(__always) static func checkedMul(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        precondition(!o, "Rational overflow in mul")
        return r
    }
}

extension Rational: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self.init(value, 1) }
}
