import XCTest
@testable import MacControlMCPCore

final class UntrustedNumericTests: XCTestCase {
    /// Non-finite values must come back nil — a coordinate/count fabricated from NaN or ±inf
    /// would be acted on (clicked at, rendered), and the plain `Int(_:)` initializer they replace
    /// would trap and abort the privileged host.
    func testNonFiniteValuesReturnNil() {
        XCTAssertNil(UntrustedNumeric.int(Double.nan))
        XCTAssertNil(UntrustedNumeric.int(Double.infinity))
        XCTAssertNil(UntrustedNumeric.int(-Double.infinity))
    }

    /// Finite but out-of-range doubles clamp to the Int bounds instead of trapping.
    func testFiniteOutOfRangeValuesClampToIntBounds() {
        XCTAssertEqual(UntrustedNumeric.int(1e30), Int.max)
        XCTAssertEqual(UntrustedNumeric.int(-1e30), Int.min)
    }

    /// In-range values truncate toward zero, matching what `Int(_:)` did for the sane inputs.
    func testInRangeValuesTruncateTowardZeroLikeIntInit() {
        XCTAssertEqual(UntrustedNumeric.int(10.7), 10)
        XCTAssertEqual(UntrustedNumeric.int(-10.7), -10)
        XCTAssertEqual(UntrustedNumeric.int(0), 0)
        XCTAssertEqual(UntrustedNumeric.int(-0.0), 0)
    }
}
