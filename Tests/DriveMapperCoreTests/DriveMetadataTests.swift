import Foundation
import Testing
@testable import DriveMapperCore

/// Fixtures captured from real `diskutil info -plist` output on macOS 26.
@Suite("DriveMetadata")
struct DriveMetadataTests {

    /// A mounted DMG. These appear under /Volumes exactly like real drives —
    /// without filtering, the catalog fills with Xcode simulator runtimes and
    /// app-updater images.
    static var diskImage: [String: Any] { [
        "BusProtocol": "Disk Image",
        "DeviceNode": "/dev/disk8s1",
        "Ejectable": true,
        "Internal": false,
        "MediaName": "",
        "Removable": true,
        "TotalSize": NSNumber(value: 566_231_040),
        "VolumeName": "Warp",
        "VolumeUUID": "39A8288F-0339-4F36-901D-1487439B05AE",
    ] }

    /// The boot volume.
    static var internalSSD: [String: Any] { [
        "BusProtocol": "Apple Fabric",
        "DeviceNode": "/dev/disk3s1s1",
        "Ejectable": false,
        "Internal": true,
        "MediaName": "APPLE SSD AP1024Z",
        "SolidState": true,
        "TotalSize": NSNumber(value: 994_662_584_320),
        "VolumeName": "Macintosh HD",
        "VolumeUUID": "AAAAAAAA-1111-2222-3333-444444444444",
    ] }

    /// A USB drive where diskutil reports "Info not available" for SolidState —
    /// the key is simply absent. This is the common case for cheap enclosures.
    static var usbUnknownType: [String: Any] { [
        "BusProtocol": "USB",
        "DeviceNode": "/dev/disk6s1",
        "Ejectable": true,
        "Internal": false,
        "MediaName": "Elements 25A3 Media",
        "TotalSize": NSNumber(value: 4_000_787_030_016),
        "VolumeName": "Backup4TB",
        "VolumeUUID": "BBBBBBBB-1111-2222-3333-444444444444",
    ] }

    /// An exFAT drive — no VolumeUUID, which is why identity needs a fallback.
    static var exFATNoUUID: [String: Any] { [
        "BusProtocol": "USB",
        "Ejectable": true,
        "Internal": false,
        "MediaName": "SanDisk Extreme SSD",
        "SolidState": true,
        "TotalSize": NSNumber(value: 2_000_398_934_016),
        "VolumeName": "SHARED",
        "VolumeUUID": "",
    ] }

    @Test("Disk images are identified and rejected")
    func rejectsDiskImages() {
        let meta = DriveMetadata.parse(plist: Self.diskImage)
        #expect(meta.isDiskImage)
        #expect(meta.isCatalogableDrive == false, "a mounted DMG must never be catalogued")
    }

    @Test("Internal drives are rejected")
    func rejectsInternal() {
        let meta = DriveMetadata.parse(plist: Self.internalSSD)
        #expect(meta.isInternal)
        #expect(meta.isSolidState == true)
        #expect(meta.isCatalogableDrive == false)
    }

    @Test("A real external USB drive is accepted")
    func acceptsExternalDrive() {
        let meta = DriveMetadata.parse(plist: Self.usbUnknownType)
        #expect(meta.isCatalogableDrive)
        #expect(meta.volumeName == "Backup4TB")
        #expect(meta.mediaName == "Elements 25A3 Media")
        #expect(meta.totalBytes == 4_000_787_030_016)
    }

    @Test("A missing SolidState key means unknown, not HDD")
    func absentSolidStateIsUnknown() {
        let meta = DriveMetadata.parse(plist: Self.usbUnknownType)
        // The distinction that matters: nil prompts the manual override in the UI,
        // false would silently mislabel an SSD as a spinning disk.
        #expect(meta.isSolidState == nil)

        let known = DriveMetadata.parse(plist: Self.exFATNoUUID)
        #expect(known.isSolidState == true)
    }

    @Test("Empty strings are normalised to nil")
    func emptyStringsBecomeNil() {
        let meta = DriveMetadata.parse(plist: Self.diskImage)
        #expect(meta.mediaName == nil, "empty MediaName shouldn't render as a blank name")

        let exfat = DriveMetadata.parse(plist: Self.exFATNoUUID)
        #expect(exfat.volumeUUID == nil, "empty VolumeUUID must not be used as identity")
    }

    @Test("Volume UUID is preferred as identity")
    func identityUsesUUID() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Backup4TB"),
            metadata: DriveMetadata.parse(plist: Self.usbUnknownType)
        )
        #expect(volume.stableIdentifier == "BBBBBBBB-1111-2222-3333-444444444444")
    }

    @Test("Drives without a UUID fall back to name and size")
    func identityFallsBack() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/SHARED"),
            metadata: DriveMetadata.parse(plist: Self.exFATNoUUID)
        )
        // Weaker than a UUID — two identically-named, identically-sized drives
        // would collide — but exFAT drives are common and worth cataloguing.
        #expect(volume.stableIdentifier == "fallback:SHARED:2000398934016")
    }

    @Test("A drive keeps the same identity across remounts at different paths")
    func identityIsPathIndependent() {
        let meta = DriveMetadata.parse(plist: Self.usbUnknownType)
        let first = MountedVolume(url: URL(fileURLWithPath: "/Volumes/Backup4TB"), metadata: meta)
        // macOS appends a suffix when the name is taken.
        let second = MountedVolume(url: URL(fileURLWithPath: "/Volumes/Backup4TB 1"), metadata: meta)
        #expect(first.stableIdentifier == second.stableIdentifier)
    }

    @Test("Missing keys degrade to safe defaults rather than crashing")
    func handlesSparsePlist() {
        let meta = DriveMetadata.parse(plist: ["VolumeName": "Weird"])
        #expect(meta.volumeName == "Weird")
        #expect(meta.isInternal == false)
        #expect(meta.isEjectable == false)
        // Not ejectable => not catalogued. Better to miss an oddball volume than
        // to index a network mount or system partition.
        #expect(meta.isCatalogableDrive == false)
    }
}
