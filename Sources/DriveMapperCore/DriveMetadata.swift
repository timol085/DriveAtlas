import Foundation

/// Hardware facts about a mounted volume, read from `diskutil info -plist`.
///
/// There's no public framework API for "is this an SSD", so shelling out to
/// `diskutil` is the standard approach. It's a one-shot call per mount, not a hot
/// path.
public struct DriveMetadata: Sendable, Equatable {
    public var volumeName: String
    public var volumeUUID: String?
    /// "USB", "Thunderbolt", "SATA", "Disk Image"…
    public var busProtocol: String?
    /// Hardware model, e.g. "Samsung PSSD T7". Often empty for generic enclosures.
    public var mediaName: String?
    public var totalBytes: Int64?
    public var isInternal: Bool
    public var isEjectable: Bool

    /// `nil` when `diskutil` omits the key — the common case for USB enclosures,
    /// which is why the app offers a manual override. Do not treat `nil` as "HDD".
    public var isSolidState: Bool?

    public var deviceNode: String?

    /// Disk images (mounted DMGs, Xcode simulator runtimes) report a bus protocol
    /// of "Disk Image". They mount under /Volumes just like real drives, so
    /// without this check the catalog fills with junk.
    public var isDiskImage: Bool {
        busProtocol == "Disk Image"
    }

    /// Whether this volume is worth cataloguing: a real, external, ejectable drive.
    public var isCatalogableDrive: Bool {
        !isDiskImage && !isInternal && isEjectable
    }
}

public enum DriveMetadataError: Error {
    case diskutilFailed(status: Int32, message: String)
    case unreadablePlist
}

extension DriveMetadata {

    /// Reads metadata for the volume mounted at `url` (e.g. `/Volumes/Backup4TB`).
    public static func read(volumeURL: URL) throws -> DriveMetadata {
        let plist = try runDiskutil(path: volumeURL.path)
        return parse(plist: plist)
    }

    /// Splits parsing out from the subprocess call so it can be tested against
    /// captured fixtures without a drive plugged in.
    static func parse(plist: [String: Any]) -> DriveMetadata {
        DriveMetadata(
            volumeName: plist["VolumeName"] as? String ?? "Untitled",
            volumeUUID: (plist["VolumeUUID"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            busProtocol: (plist["BusProtocol"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            mediaName: (plist["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            totalBytes: (plist["TotalSize"] as? NSNumber)?.int64Value,
            isInternal: plist["Internal"] as? Bool ?? false,
            isEjectable: plist["Ejectable"] as? Bool ?? false,
            // Absent key means diskutil said "Info not available" — genuinely
            // unknown, not false.
            isSolidState: plist["SolidState"] as? Bool,
            deviceNode: plist["DeviceNode"] as? String
        )
    }

    private static func runDiskutil(path: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DriveMetadataError.diskutilFailed(
                status: process.terminationStatus,
                message: String(data: errData, encoding: .utf8) ?? ""
            )
        }

        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw DriveMetadataError.unreadablePlist
        }
        return plist
    }
}

/// A volume currently mounted at `/Volumes`.
public struct MountedVolume: Sendable, Equatable {
    public var url: URL
    public var metadata: DriveMetadata

    /// Identity used as the catalog's primary key.
    ///
    /// Prefers the filesystem UUID. Some filesystems (notably exFAT, common on
    /// drives shared with Windows) don't expose one, so we fall back to a
    /// name+size composite. That's weaker — two identically-named, identically-sized
    /// drives would collide — but it beats refusing to catalog them.
    public var stableIdentifier: String {
        if let uuid = metadata.volumeUUID { return uuid }
        let size = metadata.totalBytes.map(String.init) ?? "0"
        return "fallback:\(metadata.volumeName):\(size)"
    }

    /// Every mounted volume that looks like a real external drive.
    public static func currentlyMounted() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        return urls.compactMap { url in
            guard let metadata = try? DriveMetadata.read(volumeURL: url) else { return nil }
            guard metadata.isCatalogableDrive else { return nil }
            return MountedVolume(url: url, metadata: metadata)
        }
    }
}
