import XCTest
import ApplicationServices
@testable import AXKit

/// Point-of-use eviction (ElementRegistry.evict). Registration is local-only — CFHash keying plus
/// a local AXUIElementGetPid, no cross-process AX call — so these run without an Accessibility
/// grant. The dead/hollow readiness transitions require a real dying element and are verified live
/// against the probe apps, not here.
final class EvictionTests: XCTestCase {
    func testEvictRemovesHandle() {
        let registry = ElementRegistry()
        let ref = registry.register(AXElement.systemWide()).ref
        XCTAssertNotNil(registry.element(for: ref), "registered handle should resolve before eviction")
        registry.evict(ref)
        XCTAssertNil(registry.element(for: ref), "evicted handle must be gone")
    }

    func testEvictUnknownRefIsSafeNoOp() {
        let registry = ElementRegistry()
        registry.evict("never-issued")               // must not crash
        XCTAssertNil(registry.element(for: "never-issued"))
    }

    func testEvictIsIdempotent() {
        let registry = ElementRegistry()
        let ref = registry.register(AXElement.systemWide()).ref
        registry.evict(ref)
        registry.evict(ref)                           // second eviction is a no-op, not a crash
        XCTAssertNil(registry.element(for: ref))
    }
}
