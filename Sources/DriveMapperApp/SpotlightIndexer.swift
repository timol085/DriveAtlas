import CoreSpotlight
import Foundation
import DriveMapperCore

/// Donates the catalog to the system Spotlight index.
///
/// This is the app's thesis delivered into ⌘Space: Spotlight itself can only
/// index mounted volumes, but *donated* items persist — so folders on a drive
/// sitting in a drawer stay searchable system-wide. Each drive's items live in
/// their own domain (its volume UUID), which makes the lifecycle trivial:
/// rescan = wipe domain + donate fresh, forget = wipe domain.
///
/// Lives in the app target, not core: donations are attributed to the donating
/// bundle, and the CLI has none — CLI-driven scans get picked up by the app's
/// full reindex at next launch instead.
enum SpotlightIndexer {

    /// Folder rows are rewritten on every scan, so identifiers built from row
    /// ids stay valid exactly as long as the donation that carries them — every
    /// rescan replaces both together.
    static func identifier(folderId: Int64) -> String { "folder:\(folderId)" }

    static func folderId(fromIdentifier identifier: String) -> Int64? {
        guard identifier.hasPrefix("folder:") else { return nil }
        return Int64(identifier.dropFirst("folder:".count))
    }

    /// Replaces a drive's Spotlight items with the current catalog contents.
    static func reindex(drive: Drive, store: Store) {
        guard let driveId = drive.id else { return }
        let domain = drive.volumeUUID
        let driveName = drive.name

        Task.detached(priority: .utility) {
            let folders = (try? store.foldersForIndex(driveId: driveId)) ?? []

            let index = CSSearchableIndex.default()
            // Wipe first: rescans renumber every folder row, so stale items
            // can't be updated in place — they're simply replaced.
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                donate(folders, driveName: driveName, domain: domain, to: index)
            }
        }
    }

    /// Forgotten drives leave Spotlight too.
    static func remove(volumeUUID: String) {
        CSSearchableIndex.default()
            .deleteSearchableItems(withDomainIdentifiers: [volumeUUID], completionHandler: nil)
    }

    /// Full rebuild, run once at app launch — cheap at a few thousand items,
    /// and it picks up anything a CLI scan changed while the app wasn't running.
    static func reindexAll(store: Store) {
        guard let drives = try? store.allDrives() else { return }
        for drive in drives {
            reindex(drive: drive, store: store)
        }
    }

    private static func donate(
        _ folders: [Folder], driveName: String, domain: String, to index: CSSearchableIndex
    ) {
        guard !folders.isEmpty else { return }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let items = folders.map { folder -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .folder)
            attributes.title = folder.name
            // The description is what tells you WHICH DRIVE without opening
            // anything — that's the entire point of the donation.
            attributes.contentDescription =
                "\(formatter.string(fromByteCount: folder.totalBytes)) on \(driveName) — \(folder.path)"
            attributes.keywords = [driveName, "DriveAtlas"]

            let item = CSSearchableItem(
                uniqueIdentifier: identifier(folderId: folder.id ?? 0),
                domainIdentifier: domain,
                attributeSet: attributes
            )
            // The default expiration silently evicts items after a while —
            // fatal here, since an unplugged drive can't re-donate. Never expire;
            // rescans and forgets do the cleanup explicitly.
            item.expirationDate = .distantFuture
            return item
        }

        // Batched: Core Spotlight rejects oversized single calls.
        for batch in stride(from: 0, to: items.count, by: 500).map({
            Array(items[$0..<min($0 + 500, items.count)])
        }) {
            index.indexSearchableItems(batch, completionHandler: nil)
        }
    }
}
