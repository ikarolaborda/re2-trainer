import Foundation

/// Structural discriminator: is this address actually referenced by anything?
///
/// The player's health component is owned by a live object, so some pointer in
/// memory holds its address. Coincidental signature matches -- structs that
/// merely happen to contain `1, 1200, n` -- are usually not pointed at by
/// anything. This lets us tell the two apart with a scan and no gameplay,
/// instead of asking the player to take a hit.
public enum RefFilter {

    /// Returns the subset of `addresses` that at least one 8-byte pointer in
    /// the target's memory refers to.
    ///
    /// Also counts references, because the genuine component tends to be
    /// referenced by several structures while noise has zero.
    public static func referenced(_ mem: ProcessMemory,
                                  addresses: [UInt64]) -> [UInt64: Int] {
        guard !addresses.isEmpty else { return [:] }
        let sorted = addresses.sorted()
        var counts: [UInt64: Int] = [:]

        mem.scanWritableRegions(minAddress: 0x100000000) { base, buf in
            var i = 0
            while i + 8 <= buf.count {
                let v = buf.loadUnaligned(fromByteOffset: i, as: UInt64.self)
                if v >= sorted[0] && v <= sorted[sorted.count - 1] {
                    // binary search
                    var lo = 0, hi = sorted.count - 1
                    while lo <= hi {
                        let mid = (lo + hi) / 2
                        if sorted[mid] == v { counts[v, default: 0] += 1; break }
                        if sorted[mid] < v { lo = mid + 1 } else { hi = mid - 1 }
                    }
                }
                i += 8
            }
        }
        return counts
    }
}
