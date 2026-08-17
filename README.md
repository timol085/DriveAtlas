# DriveAtlas

Catalogs what's on your external drives so you can find things without plugging
each one in.

Plug a drive in and DriveAtlas records its folder structure. After that you can
browse and search that drive whether or not it's actually connected, so
"which disk has the 2019 wedding photos?" is a search box instead of a pile of
enclosures and a free afternoon.

macOS 14+, Swift 6. A SwiftUI menu bar app and a CLI, both over the same core.

## What it does

- **Auto-catalogs on connect.** Plug in a drive and it's scanned in the
  background — no action needed. The catalog survives after you unplug it.
- **Notices changes while connected.** Edit a drive with DriveAtlas running and
  it re-scans itself once activity settles, so the catalog doesn't go silently
  stale; unplug before it does and the drive stays flagged until its next scan.
- **Quick Search from anywhere.** A ⌃⌥Space floating panel (or a click on the
  menu bar icon) finds a folder across every drive without opening a window or
  switching apps — and tells you which drive it's on.
- **Findable in system Spotlight.** Your folders are donated to ⌘Space too,
  *including drives currently unplugged* — which Spotlight itself can never
  index.
- **Backup Check.** Compares every drive to find what you have exactly one copy
  of, and what's duplicated and reclaimable.
- **Three ways to see a drive** — an indented list, a node-link map, and a
  size treemap — plus per-folder file-type breakdowns.
- **Drive health.** Type (SSD/HDD), capacity, free space, and an age warning on
  old SSDs.
- **Read-only.** Never modifies, moves, or deletes anything on the drives it
  scans — [audited, not just asserted](#read-only-by-design).

---

## Contents

- [Install](#install)
  - [Option A — download a pre-built app](#option-a--download-a-pre-built-app)
  - [Option B — build from source](#option-b--build-from-source)
- [Using the app](#using-the-app)
  - [Quick Search](#quick-search) — the ⌃⌥Space panel
  - [Spotlight](#spotlight) — finding drives from ⌘Space
  - [The three views](#the-three-views)
- [Using the CLI](#using-the-cli)
- [Permissions](#permissions)
- [Read-only by design](#read-only-by-design)
- [How it works](#how-it-works)
- [Design notes](#design-notes) — the constraints that shaped it
- [Development](#development)
- [Not built yet](#not-built-yet)

---

## Install

Two ways in, depending on how hands-on you want to be:

- **[Download a build](#option-a--download-a-pre-built-app)** — grab the `.app`
  and click through one macOS security prompt. No developer tools needed.
- **[Build from source](#option-b--build-from-source)** — clone and run one
  script. Never triggers a Gatekeeper prompt.

Either way you get the same app. The only real difference is that first launch.

### Option A — download a pre-built app

*Best for: you just want to run it and can follow a one-time "allow it" step —
no Xcode, no Terminal (usually).*

1. Download `DriveAtlas.zip` from the
   [**Releases**](https://github.com/timol085/DriveAtlas/releases) page and unzip it.
2. Move `DriveAtlas.app` into `/Applications` (optional, but tidy).
3. Double-click it. **macOS blocks it the first time** — the app is signed, but
   not with a paid Apple Developer certificate, so Gatekeeper can't verify who
   made it. This is expected, and you only clear it once.

**The normal prompt — *"Apple could not verify… is free of malware":***

   1. Click **Done** in that dialog (do *not* click "Move to Trash").
   2. Open  → **System Settings → Privacy & Security**.
   3. Scroll to the **Security** section. You'll see *"DriveAtlas was blocked to
      protect your Mac."* Click **Open Anyway**.
   4. Authenticate with Touch ID or your password, then click **Open Anyway**
      once more.
   5. It launches — and macOS remembers, so you won't be asked again.

   > On macOS 15 (Sequoia) and later, the old *right-click → Open* shortcut no
   > longer works for unverified apps. The Settings route above is the way in.

**If you instead see *"DriveAtlas is damaged and can't be opened":***

   Same block, scarier label — it does **not** mean the download is corrupt.
   macOS occasionally shows this for apps signed without a paid certificate.
   Clear the "downloaded from the internet" flag once, in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/DriveAtlas.app
   ```

   Then double-click as normal. (Change the path if you didn't move it to
   `/Applications`.)

None of this bypasses real protection — you're vouching for an app you chose to
download, the same as any tool distributed outside the App Store. DriveAtlas is
[read-only by design](#read-only-by-design) and open-source, so every line it
runs is right here to inspect.

### Option B — build from source

*Best for: you have Apple's developer tools (or don't mind installing them) and
want zero security prompts — a locally built app is never flagged as "downloaded
from the internet", so it just runs.*

Requires the Swift 6 toolchain — Xcode 16+ or the standalone Command Line Tools
(`xcode-select --install`). GRDB is the only dependency, and SwiftPM fetches it
for you.

```sh
git clone https://github.com/timol085/DriveAtlas.git
cd DriveAtlas
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

DriveAtlas needs to be running to notice a drive being connected. By default it
shows in both the Dock and the menu bar, and the window is optional — close it
and everything still runs from the menu bar icon. (Prefer a menu-bar-only
background agent with no Dock presence? See [Background agent](#background-agent).)
Turn on **Launch at Login** (the ••• button in Quick Search) so it's always
running without you remembering to open it — everything ambient (auto-scanning a
plugged-in drive, the hotkey, fresh Spotlight donations) depends on the process
actually being alive.

**Plug in a drive** → it's detected, added to the sidebar, and scanned in the
background. The menu bar icon changes while a scan runs. You can browse the
cached tree of any other drive while a scan runs.

### Quick Search

The on-demand entry point. Press **⌃⌥Space** anywhere — mid-Finder,
mid-anything — or click the menu bar icon (either mouse button), and a small
floating search box appears without switching apps or opening a window. Type,
see which drive has it, Enter or click to jump straight there; Esc or click
elsewhere dismisses it.

- **↑ ↓** move through results, **↵** opens the highlighted one. The top hit is
  selected by default, so type-and-Enter works without touching the mouse.
- **With the box empty it lists your drives**, so it doubles as a drive switcher.
- The **•••** button in the footer holds **Launch at Login**, Open DriveAtlas,
  and Quit. Everything lives on that one surface — there's no second gesture to
  learn.

⌃⌥Space avoids the two combos already spoken for on most Macs (⌘Space is
Spotlight, ⌥Space is Alfred's default); there's no in-app picker yet to change
it. It needs **no permissions at all** — see the Carbon note in
[Design notes](#design-notes) for why that took a rewrite to achieve.

### Spotlight

Your folders are also donated to macOS's own Spotlight index, so **⌘Space finds
them too** — *including drives that are unplugged*, which Spotlight on its own
can never index. A result shows the size and drive ("409 GB on Travel — Japan");
clicking it opens DriveAtlas at that folder. Donations never expire, refresh
after every scan, and are removed when a drive is forgotten. Folders under 10 MB
aren't donated (nobody ⌘Space-searches for those), capped at 3 000 per drive.

### The main window

**The sidebar** lists every drive you've ever connected, with type (SSD/HDD),
capacity, free space, and a warning triangle on SSDs over five years old. Click
one to open it; right-click for Rescan Now or Forget.

**The search field** (top of the window) searches folder names across _every_
catalogued drive, connected or not, and each hit tells you which drive it's on.
This is the in-window equivalent of Quick Search.

**Backup Check** (top of the sidebar) compares folders across every drive and
answers the question a pile of disks makes hard: _what do I have exactly one copy
of?_ It also lists what's duplicated, with how much space you'd reclaim by
keeping one copy and how closely the copies match.

It matches folders by the **file names and sizes inside them** — never file
contents — so a folder backed up under a *different name* ("Japan" on one drive,
"JP trip" on another) is still found, and two identically-named folders holding
different files are not mistaken for copies. Because it's name+size and not a
content hash, a camera reusing a filename like `001.arw` for a different photo
can look identical: treat a match as "worth checking", never a verified backup.
The overlap is whole-folder, so one such collision among hundreds of files
doesn't create a false match. Folders below 100 MB are ignored, and if a folder
has no second copy its children aren't listed separately.

Drives catalogued before this feature existed carry no file fingerprints, so
they can't be compared until rescanned — Backup Check shows a rescan banner for
them rather than an empty (and misleading) all-clear.

**Rescan a connected drive** with the toolbar's Rescan button (or right-click it
in the sidebar) after changing its contents — deleting duplicates, adding a
shoot. Unplugging and replugging does the same thing. When a rescan finishes,
Backup Check, Spotlight donations, and the views all refresh automatically.

**Change detection while connected.** If you add, remove, or edit files on a
drive while it's plugged in *and DriveAtlas is running*, it notices (via
FSEvents) and marks that drive **"Changed — rescan to update"** in the sidebar.
Then, once the drive has been **quiet for ~45 seconds** (so a big paste or an
edit-in-place session collapses into one scan rather than thrashing), it
**rescans automatically** and the badge clears. The quiet-period wait is
deliberate: it keeps a spinning HDD from spinning up on every single change.

The badge is also the safety net. If you unplug before the automatic rescan
runs — the exact "changed it, then disconnected, assumed it updated" case — the
flag is *persisted*, so it stays visible on the (now offline) drive and clears
only on the next real scan. (Changes made while DriveAtlas is closed are caught
by the automatic rescan on next connect instead.)

**Drive Info** (the ⓘ button) is where you correct what macOS couldn't detect:
the SSD/HDD type and the purchase date. Both matter; see
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

**The only subprocess it launches, `diskutil info`, is purely informational.**
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
| `DriveChangeWatcher` | FSEvents watch on a mounted drive — flags it stale and triggers the debounced auto-rescan when its contents change |
| `AppModel`      | Observable state for the UI                                         |
| `SpotlightIndexer` | Donates the catalog to system Spotlight, per-drive domains       |
| `StatusItemController` | Owns the menu bar icon directly via `NSStatusItem` — click routing, the right-click menu |
| `QuickSearchPanel` | The ⌃⌥Space floating search box (`NSPanel` + SwiftUI content) |
| `HotkeyManager` | Carbon `RegisterEventHotKey` for ⌃⌥Space — no permissions needed     |
| `LaunchAtLogin` | `SMAppService` wrapper                                              |
| `driveatlas`    | CLI over the same core                                              |

**The scan** walks the volume depth-first, inserting each folder on the way down
(so children have a parent to reference) and writing size and file-type rollups
on the way back up. Rollups are accumulated during the walk because computing
them afterwards would mean a second full pass.

**A failed scan rolls back.** The delete-and-rebuild happens in one transaction,
so if the volume's root can't be read or the volume is gone by commit time, the
scan aborts and the previous catalogue is preserved. Without that, unplugging a
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
sorted by size before the cap applies, so it always hides the smallest — sorting
by name and truncating instead meant the biggest folder on the drive could
vanish just for starting with "z". Hovering the marker lists what's behind it. That marker means
_folders_; files are never nodes in the map.

**The treemap uses three file-type colours plus a neutral "Other".** A treemap is
an "all-pairs" case — any rectangle can end up beside any other — and the
categorical palette stops clearing colourblind separation past a few slots. So the
drive's three biggest file types get hues (blue, a deep green, a rose) and everything
else folds into a neutral "Other". There's deliberately no fourth file-type hue:
the validator rejects every candidate next to those three (violet≈blue, red≈magenta,
the teal region collapsing against magenta for deutan viewers — all measured), so a
fourth colour would be one some people couldn't distinguish. The amber that once
held a fourth slot is now reserved for the **drive-root** tile, which is safe
because the root is never identified by colour alone — unique icon, position, and
legend entry. Slots are assigned per drive, so a colour means the same thing
however deep you drill.

Palette values come from a validated reference palette, checked under `--pairs
all` in both light and dark modes. Where a pair lands in a marginal contrast or
CVD band, one measure covers it: every tile carries a visible label, tiles are
separated by a 2px gap, and a legend is always present. **Don't remove the tile
labels.**

**Creation dates arrived in schema v3**, after the first scans were written.
Folders catalogued before that carry `NULL` and show as "unknown" until their
drive is rescanned. Sorting pushes unknowns to the end in _both_ directions, a
date we don't have is unknown, not oldest.

**Backup Check matches folders by their file fingerprints, never file bytes.**
Each file is fingerprinted as a stable 64-bit hash of its `(lowercased name,
size)` — see `FilePrint`, which uses FNV-1a rather than Swift's randomized
`Hasher` precisely because these are persisted and compared across scans.
`FolderMatcher` compares two folders by the Jaccard overlap of their rollup
fingerprint sets (≥ 0.80 = a copy), with a size window to keep it from being
O(n²). This is whole-folder overlap on purpose: it finds copies under different
folder names, and it's immune to the `001.arw` camera-collision because one
shared fingerprint among hundreds is noise. Storage is a packed `UInt64` blob
per folder — about 8 bytes per file, a few hundred KB for a typical library, not
the megabytes storing filenames would cost. The algorithm is pure and lives in
Core, covered by `FolderMatcherTests`; the store wiring and the "drive predates
fingerprints → rescan, don't imply all-clear" guard are in `CopyAnalysisTests`.

Hashing file *contents* would be the only way to prove identity, but it would
mean reading every byte on every drive — hours per drive, breaking the read-only
guarantee, and needing both drives present at once. Fingerprints trade that for
"worth checking, not verified", which the UI states plainly. The pre-2026 design
matched on folder *name* plus size within 5% — it caught same-named copies
(rarely byte-identical, a stray `.DS_Store` is enough) while rejecting
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

**The menu bar icon is a raw `NSStatusItem`, not SwiftUI's `MenuBarExtra`.**
`MenuBarExtra` shows a menu on click, or runs a closure on click — not one
depending on *which* mouse button, and left-click-opens-search /
right-click-shows-menu is the entire feature. `StatusItemController` routes by
inspecting `NSApp.currentEvent.type` in the button's action, then uses the
assign-a-menu-then-immediately-clear-it trick to show a real `NSMenu` only for
the instant a right-click needs one — otherwise every click would open that
menu, defeating the left-click search shortcut. Verified with a real
`CGEvent`-synthesized right-click during development, not just the debug
bridge, since `AXShowMenu` (the natural accessibility-script approach) finds
nothing — there's no menu assigned to the status item except in that instant.

**Spotlight donations and the quick-search panel share one `search`, not two.**
`AppModel.search(_:)` is pure — it reads the store and returns hits without
touching `searchQuery`/`searchResults`, the main window's own search state —
specifically so the floating panel can search without ever clobbering (or being
clobbered by) whatever the main window has on screen. `rerunSearch()` (the main
window's path) just calls it and assigns the result.

**The global hotkey uses Carbon's `RegisterEventHotKey`, not an `NSEvent`
global monitor.** The `NSEvent` version silently never fired from other apps —
verified with Input Monitoring granted (`CGPreflightListenEventAccess() ==
true`) and the callback still dead. That API is gated on **Accessibility**
trust, not Input Monitoring, because a global monitor can observe *every*
keystroke system-wide. `RegisterEventHotKey` registers one combination with the
window server and fires only for that one, so it needs no permission at all —
which also means nothing for a rebuild's changed ad-hoc signature to
invalidate. Don't pair it with a local `NSEvent` monitor "for the frontmost
case": a registered hot key already fires whichever app is frontmost, so both
handlers ran, `toggle()` fired twice, and the panel opened and instantly closed
whenever DriveAtlas was active.

**The app defines its own colours instead of using the system accent.** It used
to read `Color.accentColor`, which meant DriveAtlas's identity colour was
whatever the user had set in System Settings — and that broke *meaning*, not
just consistency. With an orange system accent, "selected" and "this drive is
nearly full" rendered as the same colour; with a blue one they separated. Which
ideas collided changed per machine, which nothing can be designed around. So
`AppColor` pins two roles and they're verified distinct with the palette
validator: ΔE 24.7 (protan) / 33.6 (normal vision) apart in light mode, 26.8 /
31.8 in dark. `AppColor.warning` means caution and nothing else — nearly-full
drives, ageing SSDs, folders with no second copy. Don't use it decoratively.

**Selection is a tint plus a leading bar, never a filled row.** `SelectionBackground`
is shared by the sidebar and the quick-search panel so they can't drift. The
system's filled highlight measured 2.62:1 against the white label text it forces
— below WCAG AA's 4.5:1 and below even the 3:1 large-text floor. Tinting leaves
the row's own text colours alone, so contrast is whatever the surrounding view
already guarantees. Note the sidebar drops `List(selection:)` entirely to
achieve this: `listRowBackground` draws *behind* the system capsule, so with a
selection binding a custom treatment just adds a bar underneath the system fill
rather than replacing it. The cost is the sidebar's built-in arrow-key
navigation; ⌃⌥Space is the keyboard path through drives and implements ↑↓
itself.

**Two traps in the quick-search panel's row lists.** First, don't put a bare
`.id(index)` on rows inside the mode-switching `ForEach`: an explicit `.id()`
overrides SwiftUI's view identity, so switching between the drive list and the
results list reused row 0's *drive* view for result 0 — the panel rendered four
drives and one folder beneath a "5 results" footer. The ids are namespaced
(`"r0"`, `"d0"`) for that reason. Second, hover selection is gated on real
pointer *movement* via `onContinuousHover`: a plain `.onHover` fires when a row
appears under an already-stationary cursor, so opening the panel near the mouse
silently moved the selection and ⌃⌥Space → type → Enter opened whatever was
under the pointer instead of the top hit.

**`SMAppService.mainApp` reports on whatever process asks it**, which is a trap
worth knowing about if you go probing this yourself: running a one-off
`swift script.swift` to check "is DriveAtlas registered" queries the *script's*
non-existent registration, not the app's — it always answers `.notFound`. The
only place `LaunchAtLogin.isEnabled` means anything is inside the running
DriveAtlas process; `DebugBridge`'s `loginstatus` command exists because of
exactly this.

---

## Development

Internal module names keep the original working title (`DriveMapperCore` etc.),
renaming every target and directory would churn the whole repo for zero user
benefit. Everything user-facing says DriveAtlas.

```
Sources/
  DriveMapperCore/     Store, Scanner, DriveMetadata, VolumeWatcher, DriveChangeWatcher, DriveCatalog
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
swift test             # 101 tests
./make-app.sh release  # the .app bundle
```

`make-app.sh` relaunches a *running* instance onto the fresh binary, so you don't
keep testing yesterday's build after a rebuild. Set `NO_RELAUNCH=1` to skip that
(e.g. when building a release artifact headlessly).

### Cutting a release

The download offered in [Option A](#option-a--download-a-pre-built-app) is just a
zipped, ad-hoc-signed `.app`. To publish a new one:

```sh
# 1. Bump the version in make-app.sh (CFBundleShortVersionString / CFBundleVersion).
# 2. Build the optimised bundle without disturbing your running copy:
NO_RELAUNCH=1 ./make-app.sh release
# 3. Zip with ditto — it preserves the code signature and macOS metadata that a
#    plain `zip` can strip, which is what turns a download into "damaged":
ditto -c -k --keepParent DriveAtlas.app DriveAtlas.zip
```

Then draft a **GitHub Release**, tag it (e.g. `v0.1`), and attach `DriveAtlas.zip`.
Both `DriveAtlas.app/` and `DriveAtlas.zip` are git-ignored — build output, not
source.

The build is only ad-hoc signed, so each user clears Gatekeeper once by hand; the
[install guide](#option-a--download-a-pre-built-app) walks them through it.
Notarising (a paid Apple Developer ID) is what would make the download
double-click-clean — worth it only once the audience outgrows "click Open Anyway".

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
driveatlas debug select-backup          # drive the sidebar selection
driveatlas debug select-drive
driveatlas debug mode:graph             # list | graph | treemap
driveatlas debug orient                 # flip the node map's growth direction
driveatlas debug snap:tag               # PNGs of every window (materials render white — artifact)
driveatlas debug dump:tag               # view hierarchy with frames — the reliable signal
driveatlas debug quicksearch:toggle     # open/close the ⌃⌥Space panel
driveatlas debug quicksearch:show       # deterministic show/hide, for scripted tests
driveatlas debug quicksearch:hide       #   (toggle-from-unknown-state gives flaky results)
driveatlas debug quicksearch:state      # is the panel visible right now?
driveatlas debug quicksearch:selection  # index of the highlighted row
driveatlas debug quicksearch:move:1     # move selection as ↑↓ would (synthesized
                                        #   arrow keys steal key focus and dismiss it)
driveatlas debug quicksearch:query:term # type into it without simulating keystrokes
driveatlas debug reveal:<folderId>      # exercise the Spotlight/quick-search click-through path
driveatlas debug spotlight:term         # query this app's own Core Spotlight donations —
                                         # they're invisible to mdfind, so this is the only way in
driveatlas debug loginstatus            # SMAppService status, read from inside the real app
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
- **A hotkey picker.** ⌃⌥Space is hardcoded in `HotkeyManager`; changing it
  today means editing the constant and rebuilding.
- **`driveatlas://` URL scheme + a Finder "Find copies in DriveAtlas" Quick
  Action**, for Raycast/Alfred/Shortcuts and right-click-in-Finder entry points.
- **Real SSD wear data.** Would need `smartmontools` and probably admin rights,
  and works on only some enclosures.
- **OS-enforced read-only.** App Sandbox with the read-only removable-media
  entitlement would make macOS itself reject any write to external volumes,
  upgrading "audited to only read" into "the OS won't allow it". Costs: the
  catalog moves into a sandbox container, and the permission flow changes.
- **Reveal in Finder** from search results and the tree views, when the drive
  is mounted.
