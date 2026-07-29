import Foundation

/// A stable 64-bit fingerprint of a single file, from its name and size.
///
/// "Fingerprint", not "hash of contents": DriveAtlas never reads file bytes
/// (see the read-only guarantee). This identifies a file by `(lowercased name,
/// size)` only — enough to tell whether two *folders* hold the same set of
/// files, never enough to prove two files are byte-identical. That distinction
/// is the whole reason folder matching needs the "worth checking, not verified"
/// caveat, and why a camera reusing `001.arw` for different photos can collide.
///
/// Must be **stable across launches** — these are persisted and compared
/// between scans. Swift's own `Hasher`/`hashValue` is seeded randomly per
/// process and would make every rescan's prints incompatible, so this is a
/// hand-rolled FNV-1a instead.
public enum FilePrint {

    public static func of(name: String, size: Int64) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037   // FNV-1a 64-bit offset basis
        let prime: UInt64 = 1_099_511_628_211

        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }

        // Case-folded name so "IMG_1.ARW" and "img_1.arw" fingerprint alike —
        // exFAT and APFS disagree on case, and a copy shouldn't miss over that.
        for byte in name.lowercased().utf8 { mix(byte) }
        mix(0)   // separator, so "ab"+"12" and "a"+"b12" can't collide
        var s = UInt64(bitPattern: size)
        for _ in 0..<8 {
            mix(UInt8(truncatingIfNeeded: s))
            s >>= 8
        }
        return hash
    }

    /// Packs a set of prints into a compact little-endian blob for storage.
    /// Sorted so equal sets serialise identically (useful for debugging/diffing).
    public static func pack(_ prints: Set<UInt64>) -> Data {
        var data = Data(capacity: prints.count * 8)
        for value in prints.sorted() {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> Set<UInt64> {
        var result = Set<UInt64>()
        result.reserveCapacity(data.count / 8)
        var index = data.startIndex
        while index + 8 <= data.endIndex {
            var value: UInt64 = 0
            for byteOffset in 0..<8 {
                value |= UInt64(data[index + byteOffset]) << (8 * byteOffset)
            }
            result.insert(UInt64(littleEndian: value))
            index += 8
        }
        return result
    }
}
