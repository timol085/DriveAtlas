# DriveAtlas

Catalogs what's on your external drives so you can find things without plugging
each one in.

Plug a drive in and DriveAtlas records its folder structure. After that you can
browse and search that drive whether or not it's actually connected, so
"which disk has the 2019 wedding photos?" is a search box instead of a pile of
enclosures and a free afternoon.

macOS 14+, Swift 6. A SwiftUI menu bar app and a CLI, both over the same core.

---

## Contents

- [Install](#install)
- [Using the app](#using-the-app)
- [Using the CLI](#using-the-cli)
- [Permissions](#permissions)
- [Read-only by design](#read-only-by-design)
- [How it works](#how-it-works)
- [Design notes](#design-notes) — the constraints that shaped it
- [Development](#development)
- [Not built yet](#not-built-yet)

---

## Install

Requires Xcode 16+ (for the Swift 6 toolchain). No other dependencies to install
by hand and GRDB is fetched by SwiftPM.

```sh
./make-app.sh release
open DriveAtlas.app
```

Drag it to `/Applications` if you want it permanently. `./make-app.sh` on its own
builds the debug configuration, which is fine for trying it but noticeably slower
on large drives.

There's no Xcode project, and you don't need one. An `.app` is just a directory
with an `Info.plist`, so `make-app.sh` assembles one from the SwiftPM build
product. You can still `open Package.swift` in Xcode if you want the GUI editor.

### App icon

Drop a square PNG in the project root and rebuild; `make-app.sh` regenerates
`AppIcon.icns` whenever the PNG is newer than it.

If the Dock keeps showing the old icon, that's Launch Services caching rather
than a build problem — `touch DriveAtlas.app`, or log out and back in.

### Background agent

By default DriveAtlas appears in both the Dock and the menu bar. To make it a
pure background agent with only the menu bar icon, set `LSUIElement` to `<true/>`
in `make-app.sh` and rebuild.

---

## Using the app

DriveAtlas needs to be running to notice a drive being connected. It lives in
the menu bar; the window is optional and can be closed.

**Plug in a drive** → it's detected, added to the sidebar, and scanned in the
background. The menu bar icon shows scan progress. You can browse the cached tree
of any other drive while a scan runs.

**The sidebar** lists every drive you've ever connected, with type (SSD/HDD),
capacity, free space, and a warning triangle on SSDs over five years old. Right-click to forget
one.

**Backup Check** (top of the sidebar) compares folders across every drive and
answers the question a pile of disks makes hard: _what do I have exactly one copy
of?_ It also lists what's duplicated across drives, with how much space you'd
reclaim by keeping one copy.

It matches on folder **name and size** — nothing reads file contents. A match
means "probably the same thing, worth checking", never a verified backup. Folders
below 100 MB are ignored, and if a folder has no second copy its children aren't
listed separately.

**The search field** searches folder names across _every_ catalogued drive,
connected or not, and each hit tells you which drive it's on. This is the feature
the app exists for.

**Drive info** (the ⓘ button) is where you correct what macOS couldn't detect
the SSD/HDD type, and the purchase date. Both matter; see
[Design notes](#design-notes).

### The three views

Toggle in the toolbar. They fail in opposite directions, which is why all three
exist.

| View      | What it shows                        | Best for                                    |
| --------- | ------------------------------------ | ------------------------------------------- |
| **List**  | Indented, expandable rows            | Folders with many children; precise reading |
| **Map**   | Node-link diagram, drive as root box | Seeing the shape of a deep tree             |
| **Sizes** | Treemap, area = disk usage           | "What's actually filling this drive?"       |

**List** sorts by name, size, file count, or date created/modified, ascending or
descending. Each level sorts independently, so the tree stays a tree. The
trailing column always shows whatever you're sorting by.

**Map** opens at the drive's top level. Click a box to expand or collapse it.
Two-finger scroll or drag to pan; pinch, ⌘-scroll, or ⌘=/⌘− to zoom (⌘0 resets);
zoom anchors on the pointer. The control bar has expand-all, collapse, an
orientation toggle (the tree can grow rightwards or downwards, rightwards suits
wide, shallow drives), and fit-to-window.

**Sizes** — click a rectangle to drill into it, breadcrumbs to come back out.
Colour is the dominant file type, with a legend along the bottom.

**Hovering any folder**, in any view, shows what file types it contains and split
into everything below it and files loose directly inside it.

---

## Using the CLI

Same catalog, no GUI. Useful for scripting, for scanning a folder that isn't a
drive, and for checking what the app is actually doing.

```sh
swift build

./.build/debug/driveatlas volumes            # mounted volumes + whether each would be catalogued
./.build/debug/driveatlas scan /Volumes/Foo  # scan a volume or any folder
./.build/debug/driveatlas drives             # list catalogued drives + free space
./.build/debug/driveatlas backup             # what has one copy, what's duplicated
./.build/debug/driveatlas tree Backup4TB 3   # print a tree, 3 levels deep
./.build/debug/driveatlas search invoices    # search every drive
./.build/debug/driveatlas watch              # auto-scan drives as they're plugged in
./.build/debug/driveatlas db                 # catalog location and size
```

`volumes` is the diagnostic one and it shows every mounted volume and why each was
accepted or rejected, which is how you check the disk-image filter is working.

Both app and CLI share `~/Library/Application Support/DriveAtlas/catalog.sqlite`.
It's plain SQLite; query it directly if you want.

---

## Permissions

macOS 13+ prompts before an app can read removable volumes. Grant it when asked,
or give DriveAtlas Full Disk Access in **System Settings → Privacy & Security**
to avoid repeat prompts.

`make-app.sh` re-signs the app ad-hoc on every build, so macOS may treat each
rebuild as a new app and prompt again.

---

## Read-only by design

DriveAtlas never modifies, moves, or deletes anything on the drives it scans.
That's a property worth being precise about, since the app exists to be pointed
at archives.

**The scanner is the only component that touches your drives and contains zero
mutating filesystem calls.** It reads directory listings and metadata
(`contentsOfDirectory`, `resourceValues`); it never opens file contents at all.

**Everything the app writes goes to its own directory.** The complete list of
write targets in the codebase:

| What                            | Where                                       |
| ------------------------------- | ------------------------------------------- |
| The catalog database (SQLite)   | `~/Library/Application Support/DriveAtlas/` |
| Debug snapshots (`DebugBridge`) | `…/DriveAtlas/debug/`                       |
| One-time rename migration       | inside `Application Support` only           |

**The only subprocess it launches is `diskutil info`** is purely informational.
No code path invokes mount, unmount, erase, or partition operations.

**"Forget drive" and rescans delete database rows**, never files on any volume.

To re-verify after changing the code, this audit should stay clean — every hit
must target the app's own directories:

```sh
grep -rn -E "removeItem|moveItem|copyItem|createDirectory|replaceItem|createFile|setAttributes|\.write\(to|unmount" Sources/
grep -rn -E "Process\(\)|executableURL" Sources/
```

Two honest caveats. First, **macOS itself touches drives you mount** in access
times, and `.Spotlight-V100`/`.fseventsd` on writable volumes the moment they
connect, with or without DriveAtlas running. The app adds nothing on top.
Second, **this is an audit, not an OS-enforced guarantee**: the app runs
unsandboxed, so only code review upholds the property. App Sandbox with the
read-only removable-media entitlement would make the OS reject writes outright;
see [Not built yet](#not-built-yet).

---

## How it works

```
        VolumeWatcher ──▶ DriveCatalog ──▶ Scanner ──▶ Store (SQLite)
     (mount events)      (coordinator)    (walks it)      │
                               │                          ▼
                         DriveMetadata            AppModel ──▶ SwiftUI views
                     (diskutil: SSD, size)
```

| Component       | Responsibility                                                      |
| --------------- | ------------------------------------------------------------------- |
| `Store`         | SQLite via GRDB — drives, folder tree, extension stats, FTS5 search |
| `Scanner`       | Background actor that walks a volume and records its structure      |
| `DriveMetadata` | Drive type/size/protocol from `diskutil`, plus disk-image filtering |
| `VolumeWatcher` | Mount/unmount notifications                                         |
| `DriveCatalog`  | Ties them together — plug in a drive, it gets catalogued            |
| `AppModel`      | Observable state for the UI                                         |
| `driveatlas`    | CLI over the same core                                              |

**The scan** walks the volume depth-first, inserting each folder on the way down
(so children have a parent to reference) and writing size and file-type rollups
on the way back up. Rollups are accumulated during the walk because computing
them afterwards would mean a second full pass.

**A failed scan rolls back.** The delete-and-rebuild happens in one transaction,
and the scan aborts, preserving the previous catalogue and if the volume's root
can't be read or the volume is gone by commit time. Without that, unplugging a
drive mid-scan silently replaced its catalogue with a nearly-empty husk: every
directory read failed and each was recorded as an empty folder.
`ScannerTests.midScanUnplugRollsBack` simulates the yanked cable.

**Storage** is four tables: `drive`, `folder`, `folder_ext` (file-type counts per
folder, stored twice — files directly inside, and everything below), and
`folder_fts`, an FTS5 index over folder names. SQLite runs in WAL mode so the UI
can read the cached tree while a scan writes.

**Files are never stored individually.** Only folders are rows; files are
aggregated into per-extension counts and sizes on their parent. That's what keeps
a multi-terabyte drive to a few tens of thousands of rows, and it's why the app
answers "what kind of things are in here" rather than "find me this filename".

---

## Design notes

The parts where reality didn't cooperate. Most of these are guarded by tests and
if you change one, expect a test to complain.

**Directory mtimes don't propagate up.** Adding a file at `a/b/c/file.txt` bumps
`c`'s mtime and leaves `a` and `b` untouched. So a rescan can't prune unchanged
subtrees — it must always traverse fully. Incremental rescanning can only ever
avoid _writes_, never I/O. `ScannerTests.rescanCatchesDeepChange` pins this down.

**SSD vs HDD is often unknowable over USB.** `diskutil` omits the `SolidState`
key entirely for many enclosures. That's stored as `nil` (unknown), never
`false`, and `Drive.isSolidStateOverride` lets you correct it by hand.

**Drive age has no reliable source, and `firstSeenAt` is not one.** SMART
power-on hours aren't exposed over USB on macOS. That leaves two honest signals,
and `Drive.AgeBasis` encodes which is which: `purchasedOn` (user-entered,
trustworthy) and `volumeCreatedAt` (filesystem creation, a lower bound only,
since it resets on every reformat).

`firstSeenAt` records when _this app_ first saw the drive and says nothing about
the hardware. An earlier version fell back to it, so a drive bought in 2018 and
plugged in for the first time today reported as brand new and the five-year SSD
wear warning could never fire for precisely the drives it existed to warn about.
Age is now `nil` when there's no basis, and an SSD without a purchase date
reports `needsAgeInfo` rather than silently reading as healthy.

**Bundles are leaves, but only some get sized.** `.photoslibrary` and `.app` are
user data, so they're measured with a flat walk but not recorded internally.
`node_modules`, `.git` and friends are recorded as a single node and _not_ sized,
walking them to measure is exactly the cost being avoided. On one `~/Projects`
folder this took the count from 36,755 folders to 4,882.

**Disk images are excluded.** Mounted DMGs and Xcode simulator runtimes appear
under `/Volumes` looking exactly like real drives. They're rejected on
`BusProtocol == "Disk Image"`. Run `driveatlas volumes` to see the filter work.

**Identity is the volume UUID**, falling back to `name:size` for filesystems that
don't expose one (exFAT often doesn't). The fallback is weaker, two identical
drives would collide but beats refusing to catalog them.

**The tree loads lazily.** A drive can hold hundreds of thousands of folders, so
`TreeNode` fetches children on expand rather than materialising the whole tree.
That's also why the list is flattened into plain rows rather than using
`OutlineGroup`, which wants the full tree up front.

**The map caps siblings at 40 per node**, with a "+N folders" marker. Past that
the diagram stops being readable well before it stops being fast. Children are
sorted by size before the cap applies, so it always hides the smallest sorting
by name and truncating meant the biggest folder on the drive could vanish for
starting with "z". Hovering the marker lists what's behind it. That marker means
_folders_; files are never nodes in the map.

**The treemap uses exactly four colours.** A treemap is an "all-pairs" case and any
rectangle can end up beside any other and the categorical palette stops
clearing colourblind separation past four slots. So the drive's four biggest file
types get hues and everything else folds into a neutral "Other". A fifth hue
would look fine to most people and be unreadable to some. Slots are assigned per
drive, so a colour means the same thing however deep you drill.

Palette values come from a validated reference palette, checked under `--pairs
all` in both light and dark modes. Two warnings came back and both are handled by
the same measure: light-mode magenta and yellow fall under 3:1 against the
surface (needs "relief", visible labels), and the dark-mode yellow/green pair
lands in the 6–8 CVD band (legal only with secondary encoding). Every tile
therefore carries a visible label, tiles are separated by a 2px gap, and a legend
is always present. **Don't remove the tile labels.**

**Creation dates arrived in schema v3**, after the first scans were written.
Folders catalogued before that carry `NULL` and show as "unknown" until their
drive is rescanned. Sorting pushes unknowns to the end in _both_ directions, a
date we don't have is unknown, not oldest.

**Backup Check matches on name and size, never content.** Hashing files would
mean reading every byte on every drive, hours per drive, and it'd need both
drives present at once to compare. Name plus size within 5% catches real copies
(they're rarely byte-identical, a stray `.DS_Store` is enough) while rejecting
the "everyone has a Photos folder" false positive, since two folders called
Photos that differ wildly in size aren't copies. The UI says so where you read
the result rather than burying it in a tooltip. Two copies on the _same_ drive
don't count and that protects you from nothing if the drive dies.

**Used space is capacity minus free, not the scan total.** The scan skips hidden
files, `node_modules`-style directories and anything unreadable, so its byte
total always undercounts what the disk actually holds. Free space is read off the
mounted volume on every connect, so it stays current without a rescan.

**Extension totals sum `ownBytes`, never `rollBytes`.** Rollups are cumulative up
the tree, so summing them across folders counts each file once per ancestor — the
two `.raf` files in the test fixture would report 900 bytes instead of 300.
`ScannerTests.topExtensionsDoNotDoubleCount` guards this.

---

## Development

Internal module names keep the original working title (`DriveMapperCore` etc.),
renaming every target and directory would churn the whole repo for zero user
benefit. Everything user-facing says DriveAtlas.

```
Sources/
  DriveMapperCore/     Store, Scanner, DriveMetadata, VolumeWatcher, DriveCatalog
  DriveMapperApp/      SwiftUI views, AppModel
  DriveMapperCLI/      the driveatlas CLI
Tests/
  DriveMapperCoreTests/
Tools/
  makeicon.swift       PNG → .icns
make-app.sh            assembles DriveAtlas.app
```

```sh
swift build            # library + CLI + app binary
swift test             # 46 tests
./make-app.sh release  # the .app bundle
```

Domain rules live in `DriveMapperCore` specifically so they can be tested and the
app target has no test coverage, which is how the drive-age bug survived as long
as it did. If you find yourself writing a rule in `AppModel.swift`, consider
whether it belongs one layer down.

The tests worth reading first are in `ScannerTests`: rescan after a deep file
addition, a rename, and a subtree deletion. Those are the cases the mtime finding
makes risky, and they're the ones that will catch a regression in the walk.

### Debugging the UI without screen access

`DebugBridge` (app side) plus `driveatlas debug <cmd>` (CLI side) let the app be
driven and inspected from a terminal that has no Screen Recording permission —
an app photographing _its own_ windows needs none:

```sh
driveatlas debug select-backup   # drive the sidebar selection
driveatlas debug select-drive
driveatlas debug snap:tag        # PNGs of every window (materials render white — artifact)
driveatlas debug dump:tag        # view hierarchy with frames — the reliable signal
```

Output lands in `~/Library/Application Support/DriveAtlas/debug/`. The frame
dumps are what found the Backup Check layout bug: `VStack { header; List }` and
`List.safeAreaInset(edge: .top)` both make a split-view detail report a huge
ideal height, which the `NavigationSplitView` adopts and centres, shoving the
whole window contents (sidebar included) out of frame, permanently. Hence the
rule in `BackupCheckView`: the detail root is one bare `List` with everything as
rows. Verify any layout change there with a `dump:` before trusting it.

### Icon generation

`Tools/makeicon.swift` exists because source art is usually opaque RGB on a white
background, which macOS would render as a white tile in the Dock. It floods the
background out _from the image border_, keying on white globally would also
punch holes in white details inside the art, squares the crop around the centre
(the drop shadow makes the tight bounding box non-square, and stretching it into
a square canvas distorts the art), and insets it to the 824-on-1024 proportion
macOS uses so it sits the same size as other Dock icons.

---

## Not built yet

- **Incremental rescanning.** Every scan is currently a full rewrite. See the
  mtime note above for what this can and can't buy.
- **Launch at login** via `SMAppService`.
- **Real SSD wear data.** Would need `smartmontools` and probably admin rights,
  and works on only some enclosures.
- **OS-enforced read-only.** App Sandbox with the read-only removable-media
  entitlement would make macOS itself reject any write to external volumes,
  upgrading "audited to only read" into "the OS won't allow it". Costs: the
  catalog moves into a sandbox container, and the permission flow changes.
- **Rescan button** for a connected drive whose contents changed — today the
  catalog refreshes on reconnect (or via `driveatlas scan`).
- **Reveal in Finder** from search results and the tree views, when the drive
  is mounted.
