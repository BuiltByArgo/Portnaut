import Foundation

/// Turns a thumbstick axis into single steps: one step each time the stick is pushed past
/// `push`, and none again until it comes back inside `release`, so holding the stick does not
/// race through a list.
public struct StickRepeat: Equatable, Sendable {
    public var push: Float = 0.6
    public var release: Float = 0.3
    var latched = false
    public init() {}

    /// -1, 0 or 1 for the axis's new value.
    public mutating func step(_ value: Float) -> Int {
        if latched {
            if abs(value) < release { latched = false }
            return 0
        }
        guard abs(value) >= push else { return 0 }
        latched = true
        return value > 0 ? 1 : -1
    }
}
