import Foundation
import GRDB

/// A physical external drive, identified by its volume UUID.
///
/// Rows persist after the drive is unplugged — that's the whole point of the app.
/// `lastSeenAt` tells you when it was last connected, `lastScannedAt` when its
/// contents were last walked.
public struct Drive: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    /// Stable identity across mounts. See `DriveIdentity` for the fallback when a
    /// filesystem doesn't expose one.
    public var volumeUUID: String
    public var name: String
    /// Hardware model string from `diskutil`, e.g. "Samsung Portable SSD T7".
    public var mediaName: String?
    /// "USB", "Thunderbolt", "SATA"…
    public var busProtocol: String?

    /// What `diskutil` reported. `nil` means it said "Info not available", which is
    /// common for USB enclosures — hence `isSolidStateOverride`.
    public var isSolidStateDetected: Bool?
    /// User's manual correction. Takes precedence over detection.
    public var isSolidStateOverride: Bool?

    public var totalBytes: Int64?
    /// Space available as of the last time the drive was connected.
    ///
    /// Read from the mounted volume, not from the scan, so it refreshes on every
    /// connect without needing a rescan. `nil` for drives catalogued before this
    /// was tracked, until they're next plugged in.
    public var freeBytes: Int64?
    /// First time this app ever saw the drive — our best automatic age signal.
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var lastScannedAt: Date?
    /// Filesystem creation date. Older than `firstSeenAt`, but resets on reformat.
    public var volumeCreatedAt: Date?
    /// User-entered. The only genuinely accurate age signal available.
    public var purchasedOn: Date?

    public init(
        id: Int64? = nil,
        volumeUUID: String,
        name: String,
        mediaName: String? = nil,
        busProtocol: String? = nil,
        isSolidStateDetected: Bool? = nil,
        isSolidStateOverride: Bool? = nil,
        totalBytes: Int64? = nil,
        freeBytes: Int64? = nil,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        lastScannedAt: Date? = nil,
        volumeCreatedAt: Date? = nil,
        purchasedOn: Date? = nil
    ) {
        self.id = id
        self.volumeUUID = volumeUUID
        self.name = name
        self.mediaName = mediaName
        self.busProtocol = busProtocol
        self.isSolidStateDetected = isSolidStateDetected
        self.isSolidStateOverride = isSolidStateOverride
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastScannedAt = lastScannedAt
        self.volumeCreatedAt = volumeCreatedAt
        self.purchasedOn = purchasedOn
    }

    /// Manual override wins; falls back to detection; `nil` when genuinely unknown.
    public var isSolidState: Bool? { isSolidStateOverride ?? isSolidStateDetected }
}

extension Drive {

    /// What, if anything, we can honestly base an age claim on.
    ///
    /// `firstSeenAt` is deliberately NOT a case here. It records when this app
    /// first saw the drive, which says nothing about the hardware's age — a drive
    /// bought in 2018 and plugged in for the first time today was "first seen"
    /// today. Using it as an age proxy made old drives look new and suppressed the
    /// wear warning on exactly the drives that needed it.
    public enum AgeBasis: Equatable, Sendable {
        /// User-entered. The only trustworthy signal.
        case purchased(Date)
        /// Filesystem creation date. A fair proxy for a drive formatted once when
        /// new, but it resets on every reformat, so it's a lower bound only.
        case formatted(Date)
        case unknown
    }

    public var ageBasis: AgeBasis {
        if let purchasedOn { return .purchased(purchasedOn) }
        if let volumeCreatedAt { return .formatted(volumeCreatedAt) }
        return .unknown
    }

    /// The date an age claim rests on, if there is one.
    public var ageReferenceDate: Date? {
        switch ageBasis {
        case .purchased(let date), .formatted(let date): date
        case .unknown: nil
        }
    }

    /// Whether this is an SSD old enough to be worth a backup nudge.
    ///
    /// Returns `false` when the age is unknown — that's an unanswered question,
    /// not a clean bill of health. `needsAgeInfo` covers that case instead.
    public func isWearRisk(thresholdYears: Int = 5, now: Date = Date()) -> Bool {
        guard isSolidState == true, let reference = ageReferenceDate else { return false }
        let years = Calendar.current.dateComponents([.year], from: reference, to: now).year
        return (years ?? 0) >= thresholdYears
    }

    /// An SSD whose age can't be established. Worth prompting for, because the
    /// wear warning is meaningless until it's filled in.
    public var needsAgeInfo: Bool {
        isSolidState == true && purchasedOn == nil
    }

    /// Space in use, derived from capacity minus free.
    ///
    /// Deliberately not taken from the scan's byte total: the scan skips hidden
    /// files, `node_modules`-style directories and anything unreadable, so its
    /// total is always an undercount of what the disk actually holds.
    public var usedBytes: Int64? {
        guard let totalBytes, let freeBytes else { return nil }
        return max(0, totalBytes - freeBytes)
    }

    /// 0–1, or `nil` when capacity isn't known.
    public var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    /// Nearly full, so the UI can warn before you try to copy onto it.
    public var isNearlyFull: Bool {
        (usedFraction ?? 0) >= 0.9
    }
}

extension Drive: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "drive"

    public enum Columns {
        public static let id = Column("id")
        public static let volumeUUID = Column("volumeUUID")
        public static let name = Column("name")
        public static let lastSeenAt = Column("lastSeenAt")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One directory on a drive.
///
/// `path` is relative to the volume root ("" for the root itself), so it stays
/// valid regardless of what `/Volumes/…` mount point the drive lands on.
public struct Folder: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var driveId: Int64
    public var parentId: Int64?
    public var name: String
    public var path: String
    public var depth: Int

    /// Size of files directly in this folder.
    public var ownBytes: Int64
    /// Size including all descendants.
    public var totalBytes: Int64
    /// File count directly in this folder.
    public var ownFileCount: Int
    /// File count including all descendants.
    public var totalFileCount: Int

    /// True when the scanner deliberately stopped here — a package like
    /// `.photoslibrary`, or a blocklisted name like `node_modules`. Its sizes are
    /// aggregate; it has no child rows.
    public var isLeafBundle: Bool

    /// Directory mtime at scan time. Used to skip redundant writes on rescan.
    /// Note: this reflects changes to *this directory's own entries only* —
    /// macOS does not propagate mtime up the tree.
    public var mtime: Date?
    /// Filesystem creation date. `nil` for folders catalogued before this was
    /// recorded — they need a rescan to pick it up.
    public var createdAt: Date?
    public var scannedAt: Date

    public init(
        id: Int64? = nil,
        driveId: Int64,
        parentId: Int64? = nil,
        name: String,
        path: String,
        depth: Int,
        ownBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        ownFileCount: Int = 0,
        totalFileCount: Int = 0,
        isLeafBundle: Bool = false,
        mtime: Date? = nil,
        createdAt: Date? = nil,
        scannedAt: Date = Date()
    ) {
        self.id = id
        self.driveId = driveId
        self.parentId = parentId
        self.name = name
        self.path = path
        self.depth = depth
        self.ownBytes = ownBytes
        self.totalBytes = totalBytes
        self.ownFileCount = ownFileCount
        self.totalFileCount = totalFileCount
        self.isLeafBundle = isLeafBundle
        self.mtime = mtime
        self.createdAt = createdAt
        self.scannedAt = scannedAt
    }
}

extension Folder: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"

    public enum Columns {
        public static let id = Column("id")
        public static let driveId = Column("driveId")
        public static let parentId = Column("parentId")
        public static let name = Column("name")
        public static let path = Column("path")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// File-extension statistics for a folder.
///
/// Stored twice per folder: `own*` counts files directly inside, `roll*` includes
/// every descendant. The rollup is what makes hovering a top-level folder useful
/// ("this branch is 400 .RAF and 12 .mov") — it's cheap to accumulate on the way
/// back up the walk and expensive to compute after the fact.
public struct FolderExtension: Codable, Equatable, Sendable {
    public var folderId: Int64
    /// Lowercased, no leading dot. Files with no extension use "".
    public var ext: String
    public var ownCount: Int
    public var ownBytes: Int64
    public var rollCount: Int
    public var rollBytes: Int64

    public init(
        folderId: Int64,
        ext: String,
        ownCount: Int = 0,
        ownBytes: Int64 = 0,
        rollCount: Int = 0,
        rollBytes: Int64 = 0
    ) {
        self.folderId = folderId
        self.ext = ext
        self.ownCount = ownCount
        self.ownBytes = ownBytes
        self.rollCount = rollCount
        self.rollBytes = rollBytes
    }
}

extension FolderExtension: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "folder_ext"

    public enum Columns {
        public static let folderId = Column("folderId")
        public static let ext = Column("ext")
        public static let rollCount = Column("rollCount")
    }
}
