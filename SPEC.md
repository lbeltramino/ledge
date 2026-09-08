# Ledge — design & build specification

A native macOS notes app. Your notes live docked at the right edge of the screen.
Reach over and they fan out.

**Status:** v1 spec, all decisions settled. Nothing here is an open question.

---

## 0. Calls I made

These override or fill gaps in the original design notes. Each is a one-line
revert if you disagree.

| Decision | Why |
|---|---|
| Name: **Ledge**. Bundle id `com.lisandro.Ledge` | `Stickies` is Apple's own app. "Ledge" describes the docked strip and survives a logo. |
| Archive bundle is `.ledge`, not `.stickies` | Follows the name; avoids implying an Apple format. |
| Verb is **Archive** / **Restore to deck**, not "Mark complete" | The state is called `archived` everywhere else. One word for one concept. |
| The archive is **not a separate window** — ⌥⌘L opens All Notes with the Archived filter pre-selected | Identical behaviour to what the notes describe, half the code, one place to maintain. |
| ~~Note bodies in New York, not handwriting~~ → **bodies are handwritten (Caveat)** | Reversed on your note. The handwriting is doing real work — it is half of why the notes read as paper rather than as UI. Kept, with its actual weakness fixed surgically rather than by replacing the face: see §6. |
| The deck is **never square to the edge** | Your screenshots showed notes slightly overlapped and slightly off-axis. That is not sloppiness in the mockup, it is the thing that makes them read as objects. Now a first-class primitive, not a styling afterthought: see §4.6. |
| The deck lives on the **menu-bar display only** in v1 | Following the pointer across displays is delightful and fiddly. Not v1. |
| **macOS 26+** only | A new app in 2026 targeting the current OS keeps one coherent design language instead of two. |
| Notes folder defaults to `~/Documents/Ledge/`, **not** an iCloud container | The user can move it into iCloud Drive themselves. All I/O is coordinated from day one, so it works when they do — without shipping a ubiquity container in v1. |

---

## 1. The product in one page

Four states, one movement.

**At rest** — a 12 pt pill on the right edge, one coloured dash per note. No
window, no Dock icon, nothing running that you can see.

**Reach over** — the pointer enters, and the notes shingle down the edge 45 ms
apart, each a coloured tab wearing its own label. No click. Nothing has taken
focus. Whatever you were typing in is still where you left it.

**Hover a tab** — that note slides clear of the deck at full size, far enough to
read every line. Still a preview. Still no focus change.

**Click it** — now it's yours. Type, and it writes itself to disk 250 ms after
you stop.

Two windows sit behind that: **⌥⌘A** opens every note in one searchable list;
**⌥⌘L** opens the same list filtered to the archive. **⌥⌘N** makes a new note
from anywhere.

Archiving pulls a note off the edge without losing it — colour, dates, tags and
searchability all intact. It is out of the deck, not out of the app.

---

## 2. Platform & stack

- **Swift 6**, strict concurrency. macOS 26.0 minimum.
- **AppKit shell, SwiftUI content.** Not negotiable in either direction:
  - AppKit owns the deck (`NSPanel` subclass), window levels, tracking areas,
    focus choreography, global hotkeys. SwiftUI cannot express a non-activating
    floating panel that declines to steal key status.
  - SwiftUI owns the All Notes window — it is a list plus a detail pane, and
    SwiftUI builds that in a fraction of the time.
  - The note editor is **NSTextView on TextKit 2**, wrapped in
    `NSViewRepresentable`. `TextEditor` gives up too much: insertion-point
    control, undo grouping, link detection, selection affinity.
- **No third-party dependencies** except:
  - `Sparkle` — updates.
  - `KeyboardShortcuts` — wraps Carbon `RegisterEventHotKey`. See §7.
  - SQLite via the system `libsqlite3`, thin hand-rolled wrapper. No GRDB; the
    index is 3 tables and deserves 300 lines, not a framework.
- **Sandboxed**, with a security-scoped bookmark for the notes folder. Signed
  with a Developer ID, notarised, distributed directly with Sparkle. The
  sandbox is hygiene, and it keeps the Mac App Store possible later.
- **`LSUIElement = true`.** No Dock icon, no menu bar item, no main menu until a
  window is open.

---

## 3. Storage

**Markdown files are the truth. SQLite is a cache you may delete at any time.**

```
~/Documents/Ledge/              # user-relocatable
  Office.md
  Groceries.md
  Side-projects.md
  .index.sqlite3                # derived, disposable
```

### 3.1 File format

Filename is derived from the title. Identity lives in the frontmatter, so
retitling renames the file without the app losing the note.

```markdown
---
id: 01K2F3QW8N4Z7YB0PMRTXAGH5J
title: Office
color: blue
state: active
rank: a0V
tags: [work]
created: 2026-08-29T21:06:12Z
updated: 2026-08-29T21:31:44Z
---
- understand all the apis listed
- create tickets for PRD creation
```

- `id` — ULID. Lexicographically sortable, generated once, never changes.
- `state` — `active` | `archived`. Archived notes stay in the **same flat
  folder**. A separate `Archive/` subfolder is more legible in Finder but puts
  state in two places (path *and* frontmatter) that can disagree, and a
  move-plus-edit race under sync duplicates the note. Flat wins.
- `rank` — fractional index (see §3.4).
- Filename collisions get ` 2`, ` 3` suffixes. An untitled note is
  `Untitled note.md`.
- Unknown frontmatter keys are **preserved verbatim** on rewrite. Someone else's
  tool may be writing there.
- A file with no frontmatter is still a valid note: the app adopts it, using
  the filename as title and the first heading or line as the snippet, and
  writes frontmatter on first save.

### 3.2 The index

```sql
CREATE TABLE notes (
  id       TEXT PRIMARY KEY,
  path     TEXT NOT NULL,
  title    TEXT NOT NULL,
  color    TEXT NOT NULL,
  state    TEXT NOT NULL,
  rank     TEXT NOT NULL,
  tags     TEXT NOT NULL,      -- JSON array
  created  TEXT NOT NULL,
  updated  TEXT NOT NULL,
  mtime    REAL NOT NULL,      -- reconciliation only
  size     INTEGER NOT NULL,   -- reconciliation only
  hash     TEXT NOT NULL,      -- reconciliation only
  width    REAL,               -- ephemeral UI state
  height   REAL
);
CREATE INDEX notes_state_rank ON notes(state, rank);

CREATE VIRTUAL TABLE notes_fts USING fts5(
  title, body, tags,
  content='', tokenize='porter unicode61', prefix='2 3'
);

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- schema_version
```

The discipline that keeps it light: **no migrations, ever.** If the file is
missing, unreadable, or its `schema_version` does not match the binary, delete
it and rebuild from the folder. A derived cache that needs migration logic has
stopped being a cache.

Note the split: frontmatter carries what *means* something and should sync —
title, colour, state, rank, tags, dates. The index carries what is merely
convenient — per-note window size, scroll offset. Losing the second on a
rebuild is invisible; it falls back to defaults. This is what makes "disposable"
an honest claim rather than a slogan.

### 3.3 Reading, writing, reconciling

Anything can edit those files — you in another editor, iCloud dropping one in.

- **Every** read and write goes through `NSFileCoordinator`. Not just when the
  folder is in iCloud Drive — always, so nothing changes when the user moves it
  there.
- Writes are **atomic**: temp file in the same directory, then `rename()` over
  the target. There is never a half-written note on disk.
- An `FSEvents` stream watches the folder. On an event, `stat` the changed paths
  and compare `(mtime, size)` against the index; re-parse only what actually
  differs. Same cheap stat-sweep on launch.
- **Echo suppression:** every write records `(path, expected hash)` in a
  short-lived set. The watcher drops events matching an entry, so a 250 ms
  autosave never bounces back as an external change.
- **Conflicts:** iCloud will produce conflict copies. v1 keeps both files, shows
  the newer in the deck and flags the pair in All Notes. No merge UI.

### 3.4 Ordering

`rank` is a fractional index — a short base-62 string where a value can always
be minted between any two neighbours (`a0`, `a0V`, `a1`). Dragging one note in
the deck rewrites **exactly one file**. A plain integer `order` would rewrite
every file below it, which is a sync storm for a cosmetic change.

---

## 4. The deck

The deck is a single `NSPanel` subclass on the menu-bar display, flush to the
right edge, vertically centred. If the Dock is on the right, the panel offsets
left by the Dock's width.

```swift
panel.styleMask          = [.nonactivatingPanel, .borderless]
panel.level              = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.isOpaque           = false
panel.backgroundColor    = .clear
panel.hasShadow          = false          // cards draw their own
panel.becomesKeyOnlyIfNeeded = true
```

`.fullScreenAuxiliary` is the quiet win: the deck is available over a
full-screen Xcode or Safari, which is exactly where you want a note.

### 4.1 The three states

**Rest.** 12 pt of visible pill against the edge, 6 pt corner radius, one
8 × 3 pt dash per note with 5 pt gaps, in each note's colour, in rank order.
The panel is actually **24 pt wide** — 12 pt of transparent margin to the left
of what it paints.

That margin is the whole trick. An `NSTrackingArea` covering the full 24 pt
catches the pointer before it reaches the edge, so the fan feels instant —
**and it needs no permission at all.** The obvious implementation,
`NSEvent.addGlobalMonitorForEvents`, demands Accessibility access, and a
premium app does not open with a scary permission dialog.

**Fan.** After an **80 ms dwell** — enough to ignore a pointer merely crossing
to a scrollbar — the notes shingle down the edge. Each becomes a 22 × 76 pt
tab, radius 5 pt on the left corners only (it is flush to the edge), 4 pt apart,
carrying its title rotated 90°. Each keeps its colour. **45 ms stagger,
top to bottom.** A `+` button sits below the last tab.

Nothing has taken focus. The panel is non-activating; the app you were typing in
is still key.

**Open.** Hovering a tab slides that note clear of the deck at full size —
264 × 316 pt by default, radius 10 pt, 16 pt padding — far enough left to read
every line. Still a preview, still no focus change.

Clicking the card activates it: the panel takes key status, the caret lands, and
the note is yours until you press Escape or click away.

### 4.2 Motion tokens

| Token | Value |
|---|---|
| `hoverDwell` | 80 ms |
| `leaveGrace` | 250 ms |
| `fanOut` | spring, response 0.32, damping 0.80, stagger 45 ms, top→bottom |
| `fanIn` | 0.20 s ease-out, stagger 24 ms, bottom→top |
| `cardSlide` | spring, response 0.28, damping 0.85 |
| `pressFeedback` | scale 0.985, 90 ms |

Retreat is faster than approach. Something that leaves as slowly as it arrives
feels reluctant.

Under `accessibilityDisplayShouldReduceMotion`, every stagger collapses to zero
and every spring becomes a 120 ms cross-fade.

### 4.6 Nothing sits square

A stack of real sticky notes never aligns, and no single note is ever parallel
to the edge of the desk. The deck reproduces that, deliberately.

Every note carries a `Jitter`, derived from its `id`:

| Property | Range |
|---|---|
| `tabRotation` | ±0.6° |
| `tabProtrusion` | 0–2.5 pt — how far the tab pokes out past its neighbours |
| `tabOverlap` | 2–5 pt — tabs **overlap**, they do not sit in a neat 4 pt rhythm |
| `cardRotation` | ±1.4° |
| `cardOffsetX` / `cardOffsetY` | ±2 pt / ±3 pt |
| `shadowScale` | 0.85–1.15, so no two shadows match |
| `paperTint` | ±1, a hair lighter or darker than the swatch |

Three rules make this feel handled rather than broken:

1. **It is derived, never random.** The values come from a hash of the note's
   ULID, so a note leans the same way on every launch, on every redraw, forever.
   A deck that re-rolled its angles on each fan-out would read as a rendering
   bug, not as paper.
2. **Nothing lands square.** The distribution is biased away from zero — a note
   sitting at 0.02° looks like a mistake, not a choice.
3. **A card straightens under the caret.** `cardRotation(focused:)` returns 0
   once you click in to write. Crooked while you read, level while you write,
   which is what you do with paper anyway. It is also what makes the handwriting
   face legible at the moment legibility actually matters.

The overlap is the load-bearing one. Evenly spaced tabs read as a segmented
control; tabs that bite 2–5 pt into each other read as a stack of things.

There is deliberately **no vertical offset** for tabs. In a vertical stack, a Y
offset and `tabOverlap` are the same knob: jittering both makes them fight, and
the visible overlap drifts to 1.8–7.2 pt instead of the 2–5 the design asks for.
Protrusion is the axis that is actually free.

### 4.3 Focus choreography

This is the part that makes or breaks the feel, so it gets stated precisely:

1. Hover, fan, preview — **no focus change whatsoever.**
2. On click into a card: record `NSWorkspace.shared.frontmostApplication`, then
   `NSApp.activate()` and make the panel key.
3. On Escape, click-away, or collapse: commit the note, resign key, and
   re-activate the recorded application.

Step 3 is what people notice. Without it, dismissing a note dumps you on the
Finder and you have to go find your editor again.

### 4.4 Collapse

The deck fans in when the pointer has been outside the panel bounds for 250 ms,
or immediately on Escape. An activated note holds the deck open until it is
dismissed.

### 4.5 Keyboard

While fanned: `↑` `↓` move selection, `↵` opens, `⌘⌫` archives, `esc` collapses.

With one honest caveat: keyboard navigation only exists when the deck was
summoned **by keyboard** (`⌥⌘D`, or `⌥⌘N`). Fanning by hover deliberately takes
no focus, so there is no key window for arrow keys to route through. That is the
trade the non-activating panel buys, not an oversight.
Every tab carries a VoiceOver label of `"<title>, <color> note, <state>"`.

---

## 5. Colour

Five papers. Names are user-visible.

| Name | Light paper | Dark paper | Tab / dash |
|---|---|---|---|
| Blue | `#B6D8F2` | `#1E3448` | `#4F9BD4` |
| Green | `#B4E3C4` | `#1D3F2C` | `#4FAE72` |
| Lavender | `#D3C3EE` | `#302748` | `#8B6FCB` |
| Butter | `#FBDF7E` | `#453516` | `#D5A521` |
| Coral | `#F4B3AA` | `#4A2622` | `#D4695C` |

Ink is `#1C1917` on light papers, `#F0EBE3` on dark. Every pair clears 7:1.

Colour is never the only carrier of meaning — a tab always shows its title, a
list row always shows its state badge. The palette is how you recognise a note
across the room, not how you read it.

Chrome neutrals are warm, biased a few degrees toward the Butter paper so the
window never reads as cold grey next to the notes:
`#FBF9F5` / `#EFEBE3` / `#78716C` / `#1C1917`.

---

## 6. Typography

| Role | Face | Size / spacing |
|---|---|---|
| Note body | **Caveat** (bundled, SIL OFL 1.1) | 17 pt / 1.5 |
| Note body, Legible mode | New York (`.serif`) | 14 pt / 1.45 |
| Note title | SF Pro Text, semibold | 14 pt |
| Tab label | SF Pro Rounded, semibold, uppercase | 9 pt, +0.06 em tracking |
| Window chrome | SF Pro Text | 13 pt |
| Metadata | SF Pro Text | 11 pt, secondary ink |

Handwriting is the default. It is not decoration — with the jitter in §4.6 it is
what stops a note reading as a rounded rectangle with text in it.

Its real weakness is narrow and gets fixed in kind rather than by abandoning the
face:

- **Size, not scale.** Caveat's x-height is small; 17 pt is the minimum where it
  reads as comfortably as SF Pro Text at 13. It is set larger than a UI face,
  not the same size in a different font.
- **Anything that must be read exactly opts out.** Inline code spans, URLs, and
  fenced blocks render in SF Mono. Handwriting is for your words, not for a
  token you are going to paste into a terminal.
- **It straightens and levels while you write** — §4.6.
- **Legible mode** switches bodies to New York for anyone who wants it, and is
  the automatic choice under `accessibilityDisplayShouldIncreaseContrast`.

Caveat is SIL OFL 1.1, so it ships inside the bundle with no licence to buy and
no network fetch. The `OFL.txt` goes in `Resources/`, and the licence is named in
the About window.

Chrome is never handwritten. Titles, buttons and list rows are SF Pro — the
handwriting is the note, the sans is the app, and keeping that line sharp is
what stops the whole thing looking like a novelty.

The editor renders Markdown as **live syntax highlighting**, not a preview
pane: `#` headings scale up, `-` list markers dim and hang in the margin, `**`
bolds while its asterisks fade to 30 %, links underline and become clickable
with ⌘. The source is always there and always editable. There is no edit/preview
toggle, because a sticky note is too small to have two modes.

## 7. Windows & shortcuts

`LSUIElement` means these must be **real global hotkeys**, registered through
Carbon `RegisterEventHotKey` (via `KeyboardShortcuts`). Not
`NSEvent.addGlobalMonitorForEvents` — that route needs Accessibility permission
for the same result. All three are rebindable in Settings.

| Shortcut | Action |
|---|---|
| **⌥⌘N** | New note — fans the deck, creates it, focuses the caret |
| **⌥⌘A** | All Notes |
| **⌥⌘L** | All Notes, Archived filter pre-selected |

### All Notes

880 × 620 pt, `titlebarAppearsTransparent`, `titleVisibility = .hidden`.
Sidebar on a `.sidebar` material; detail pane on chrome neutral.

**Left:** search field, an `All / Active / Archived` segmented filter, the note
count, and the list. Each row: a selection checkbox, a 3 pt colour bar, title,
one-line snippet, state badge, relative time.

**Right:** the selected note as its own coloured card, at reading width, with
`Archive` / `Restore to deck`, `Export…` and `Delete` above it and
`Created … · Updated …` below.

Selecting more than one row swaps the detail pane for a count and the export
controls.

### Search

FTS5 over title, body and tags, weighted 3 / 1 / 2, `porter unicode61`,
`prefix='2 3'` so it matches as you type. 80 ms debounce. Results show an FTS
`snippet()` with the match emphasised. Archived notes are included unless the
filter excludes them — that is the promise the archive makes.

---

## 8. Export & import

Multi-select in All Notes, then `Export…`. Four formats:

| Format | Output |
|---|---|
| **Markdown** | One `.md` per note, frontmatter stripped, title as `# H1`. For other apps. |
| **Plain text** | One `.txt` per note. Title, blank line, body verbatim. |
| **Single file** | Every selected note in one `.md`, each as `## Title` separated by `---`. |
| **Ledge archive** | A `.ledge` zip: the raw `.md` files *with* frontmatter, plus `manifest.json` (schema version, export date, count). |

`.ledge` is the only lossless one, and it is nearly free — the notes are already
Markdown files on disk, so the archive is the folder plus a manifest. Importing
one restores colours, states, tags and dates exactly; ids that already exist are
imported as copies with fresh ids rather than overwriting.

Multi-file exports use an `NSOpenPanel` in directory mode.

---

## 9. First run

No modal, no tour. On first launch Ledge creates the folder, writes one welcome
note that explains the three states, places the pill, fans the deck open once on
its own, holds for a beat, and settles back to rest.

You learn the app by watching it do the only thing it does.

Zero notes: the pill is a single dim dash; hovering fans out to just the `+`.

---

## 10. What v1 is not

A fence, so the scope stays honest:

- No rich text, attachments, or images. Markdown files, plain.
- No reminders, due dates, or checkboxes-as-state.
- No sharing, collaboration, or accounts.
- No iOS app.
- ~~No per-display decks~~ → **strips**. A strip is one edge of one screen; a
  note carries its `strip:` in frontmatter, and moves between them by being
  dragged. On a laptop there is one and you never think about it.
- No sync conflict merge UI. Both copies are kept, and — see §13 — not yet flagged.
- No plugin API.

---

## 11. Project layout

```
Ledge/
  App/        AppDelegate, hotkeys, first-run, Settings
  Deck/       DeckPanel, DeckController, TabStrip, NoteCard, Motion
  Editor/     NoteTextView (TextKit 2), MarkdownHighlighter
  Library/    AllNotesWindow (SwiftUI), Search, Export, Import
  Store/      NoteStore, CoordinatedFileIO, Frontmatter, FolderWatcher
  Index/      Database, Schema, Rebuild, FTS
  Design/     Palette, Typography, Motion, Jitter
  Resources/  Caveat-*.ttf, OFL.txt
```

## 12. Build order

1. **Store + Index + watcher, headless, with tests.** Frontmatter round-trips,
   atomic writes, echo suppression, rebuild-from-folder, FTS. Everything above
   reads from this, and it is the layer where a bug means lost notes.
2. **The deck.** Pill → fan → preview → open, plus focus choreography. Build it
   rough, then spend real time on the motion. This is where the app is won or
   lost, and no amount of polish elsewhere compensates.
3. **The editor.** TextKit 2, live Markdown highlighting, 250 ms debounced save.
4. **All Notes** and search.
5. **Export and import.**
6. **First run, accessibility, reduced motion, the polish pass.**

## 13. Built since, and what is still open

The gaps §13 used to list, and where they went.

| Was missing | Now |
|---|---|
| **Tags** — round-tripped and searchable, but no way to set one | Written in the note itself: `#work` is a tag, `# Heading` is not. Removing the hashtag removes the tag; a tag written by hand into the frontmatter is never taken away, because Ledge did not put it there. Clickable in All Notes. |
| **Sync conflicts** | Detected by **frontmatter id**, not by filename, so it holds whatever iCloud names the copy. Both files are always kept: the one edited later keeps the identity, the other becomes an ordinary note titled `(conflicted copy)` and tagged `conflict`, so every one of them is one search away. |
| **`pressFeedback`** | Applied — tabs, buttons, swatches. Suppressed under Reduce Motion. |
| **First-run demonstration** | The deck fans, opens the welcome note, holds, and puts it away. Shown once, on a genuinely empty folder. |
| **Signing and notarisation** | Plumbed and gated: `Ledge.entitlements` (sandbox, user-selected files, app-scoped bookmarks, network client), a `codesign` step in `bundle.sh` that runs when `LEDGE_SIGN_IDENTITY` is set, and a notarisation step in the release workflow that runs when the secrets exist. Until a Developer ID is added, releases go out unsigned and say so. |
| **Sparkle** | **Deliberately not adopted.** Sparkle installs updates, and installing over an unsigned app that Gatekeeper had to be talked into replaces a binary the user vouched for with one they did not. Instead: one request a day to GitHub's public API, a menu item when a newer release exists, and a link. Switchable off. |

Since then: an app icon, drawn by the app itself at every size macOS wants, and
strips that follow an app — tell one to show with Xcode and it comes out when
Xcode does. Both were on the "what would make this a product" list rather than
the "what is broken" one.

Still open: the notes folder can be moved and lives happily in iCloud Drive, but
there is no merge UI for a conflict — you get both notes and decide. And the
sandbox is declared and inert until something signs the app.

## 14. Verifying the deck without eyes

The deck is hand-computed frames, rotations and overlaps — the kind of thing
that reads correctly in the source and is wrong on screen. `Ledge --selftest`
drives the panel through rest → fanned → open → editing → rest and asserts the
geometry it actually produced: that the panel hugs the visible screen edge, that
every tab is flush, that the measured overlaps land in 2–5 pt with no two
identical, that no tab sits square, that the card clears the tab column and is
not clipped, and that it levels out under the caret.

It found both layout bugs in the first deck build.
