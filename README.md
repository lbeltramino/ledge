# Ledge

A native macOS notes app. Your notes live docked at the edge of the screen —
at rest a thin coloured stripe, and when you reach over, they fan out.

```
        ┌──────────────────────────────┐   ┌──────────────────────────────┐
        │                              │   │                        ▐OFFICE
        │                              │   │                        ▐GROCERI
        │                            ▐  │   │                        ▐HOLD
        │                            ▐  │   │      ┌───────────────┐▐SIDE-PRO
        │                            ▐  │   │      │ Groceries     │▐
        │                            ▐  │   │      │ - apple       │▐  ⊕  ⊙
        │                              │   │      └───────────────┘▐
        └──────────────────────────────┘   └──────────────────────────────┘
              at rest: a 12 pt pill             reach over: the deck fans
```

**Every note is a plain Markdown file.** The folder is the source of truth; the
SQLite index beside it is a cache you can delete at any moment.

---

## What it does

- **The deck.** A strip of tabs on any edge of any screen. Hover and it fans;
  hover a tab and that note grows out of it at full size. Nothing takes focus
  until you deliberately click into a note to write — the app you were typing in
  stays exactly where it was.
- **Several strips.** One on a laptop, or four on a 49-inch display: left edge,
  right edge, and either side of the Dock. Drag a note from one to another.
- **Pull a note off.** Drag it away and it floats on the desk until you push it
  back to an edge.
- **Live Markdown.** Headings, lists, bold, links, inline code and fenced blocks
  are highlighted as you type — no preview pane, because a sticky note is too
  small to have two modes.
- **Everything in one list.** `⌥⌘A` searches titles, bodies and tags across every
  note, archived ones included.
- **Export.** Markdown, plain text, a single file, or a `.ledge` archive that
  imports back with colours, states, tags and dates intact.

## Requirements

macOS 15 or later, and a Swift 6 toolchain. **Xcode is not required** — the Swift
Command Line Tools are enough.

## Build and run

```sh
./Scripts/bundle.sh          # produces build/Ledge.app
open build/Ledge.app
```

Notes are written to `~/Documents/Ledge` by default. To point it somewhere else
while you are trying it out:

```sh
LEDGE_FOLDER=/tmp/notes ./build/Ledge.app/Contents/MacOS/Ledge
```

## Tests

```sh
swift run ledge-tests                               # 72 unit tests
./build/Ledge.app/Contents/MacOS/Ledge --selftest   # 360+ geometry checks
```

Note it is `swift run`, not `swift test`. The Command Line Tools ship
`Testing.framework` without its `_Testing_Foundation` module, and XCTest needs
full Xcode, so the suite is a plain executable target instead. `suite` / `test` /
`expect` map one-to-one onto `@Suite` / `@Test` / `#expect`, so it converts back
the day Xcode is installed.

The `--selftest` pass is the unusual one. The deck is hand-computed frames,
rotations and overlaps — the kind of thing that reads correctly in the source and
is wrong on screen. So the app drives itself through every state, at every size
it offers, on every edge, and asserts the geometry it actually produced: that
tabs are flush with the screen, that they overlap by 2–5 pt with no two gaps
alike, that no tab sits square, that a title is never clipped by the edge of its
tab, that a label reads downward (checked by rendering it to a bitmap and reading
the pixels back), and that every ink-on-paper pair clears its contrast ratio.

It has caught real bugs: a card covering the tab it belonged to, vertical jitter
fighting the tab overlap, titles sliced off by the screen edge, and a deck taller
than the display.

## How it is built

```
LedgeCore    Note model, frontmatter, ULID, fractional ranks, jitter
LedgeIndex   SQLite + FTS5 — a derived cache, deletable at any moment
LedgeStore   coordinated file I/O, FSEvents watcher, reconciliation, export
LedgeApp     AppKit shell: panels, strips, cards, editor, library
```

No package dependencies. The SQLite wrapper is ~300 lines over the system
`libsqlite3`; the ZIP container behind `.ledge` archives is written from scratch
so an archive is a real zip you can open in the Finder.

### The one thing to know before changing anything

**Markdown files are the truth. The index is a cache.**

Every mutation writes the file first and the index second. If the two ever
disagree, the folder wins — `rebuildIndex()` is always safe to call. The index
carries no migration logic on purpose: a schema mismatch deletes the file and
rebuilds it from the folder. A derived cache that needs migrating has stopped
being a cache.

What follows from that: anything that must survive lives in the frontmatter —
title, colour, state, tags, dates, deck order, and which strip the note sits on.
Anything merely convenient lives in the index — a note's window size, for
instance. Losing the second on a rebuild costs nothing but a default.

### A note file

```markdown
---
id: 01K2F3QW8N4Z7YB0PMRTXAGH5J
title: Office
color: blue
state: active
rank: a0V
tags: [work]
strip: left-1
created: 2026-08-29T21:06:12Z
updated: 2026-08-29T21:31:44Z
---
- understand all the apis listed
```

`id` is a ULID and never changes, so retitling renames the file without the app
losing the note. `rank` is a fractional index, so dragging one note in the deck
rewrites exactly one file instead of every file below it. Keys written by other
tools are preserved verbatim.

## Design decisions worth knowing

- **The panel paints 12 pt but is 24 pt wide.** The extra is transparent, and a
  tracking area over it catches the pointer before it reaches the screen edge.
  The obvious alternative — a global mouse monitor — demands Accessibility
  permission for the same result, and a premium app should not open with a scary
  dialog.
- **Global shortcuts go through Carbon `RegisterEventHotKey`**, not
  `NSEvent.addGlobalMonitorForEvents`, for the same reason.
- **The deck is a non-activating `NSPanel`.** Hovering, fanning and previewing
  never touch focus. Only a click into a note activates Ledge — and dismissing it
  puts focus back where it came from.
- **Nothing sits square.** Every note has a rotation, offset, tab overlap and
  paper tint derived from a hash of its id, so it leans the same way forever
  rather than re-rolling on each redraw. A card straightens under the caret:
  crooked to read, level to write.
- **`LSUIElement`, but with a main menu.** Nobody sees it; it exists because the
  main menu is where ⌘C, ⌘V and ⌘Z are *defined*.

`SPEC.md` has the full specification: motion tokens, geometry, palette,
typography, and the build order the project followed.

## Not in v1

No rich text, attachments or images. No reminders. No sync of its own — the notes
folder can be moved into iCloud Drive and all I/O is coordinated from day one, so
it works, but there is no conflict-resolution UI. No plugin API.

## Licence

MIT, see `LICENSE`. The bundled Caveat typeface is SIL OFL 1.1 — see `NOTICE.md`.
