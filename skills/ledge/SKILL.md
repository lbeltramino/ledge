---
name: ledge
description: Keep a Ledge note updated as a live progress feed for a long task — create the note, add and tick checklist items, append findings. Use when the user asks to be kept posted on progress, wants a task tracked in their notes, or mentions Ledge notes.
---

# Keeping a Ledge note as a progress feed

Ledge is a macOS notes app. Its notes are plain `.md` files in a folder, and the
`ledge` command writes to them. The app is watching that folder, so anything you
write shows up on the user's screen within about 150 ms — a dot appears on the
note's tab, and stays until they look at it.

This is a way to keep someone posted without interrupting them. Use it when a
task is long enough that they would otherwise have to ask.

## Check it is there

```bash
ledge folder          # prints where the notes live
```

If the command is not found, the user has not installed Ledge, or not put it on
the PATH — say so and carry on without it. Do not fall back to writing `.md`
files into the notes folder yourself: the app writes through file coordination
and a plain write can land in the middle of one of its saves.

## At the start of a task

```bash
ID=$(ledge new "Migrate the billing service" --feed claude-code)
```

`--feed` is what marks the note as written-to by something other than the user;
it is what puts the indicator on the tab. Use a name that says what is writing —
`claude-code` is a good default. Keep the id: every other command takes it.

There is also `--strip NAME`, which puts the note on one of the extra edges of
the screen the user may have set up. Only pass it if they named one: a strip
that does not exist is not an error, the note simply lands on the main deck.

Then lay out the plan as tasks:

```bash
ledge task add "$ID" run the schema migration
ledge task add "$ID" switch the read path
ledge task add "$ID" backfill and verify
```

## As you go

Tick things off as they actually finish, not when you start them:

```bash
ledge task check "$ID" schema migration
```

Matching is on the words, not on a position, so quote enough of the task to be
unambiguous. It ignores case and accents. Ticking something already ticked is
not an error — it prints `already done:` and changes nothing.

Append what the user would want to know, and nothing else:

```bash
ledge append "$ID" -- "Backfill ran in 4m12s. 3 rows failed validation, all from
the 2019 import — listed in /tmp/failed.csv."
```

Long or multi-line text can go on stdin instead:

```bash
some-command | ledge append "$ID"
```

## Reading it back

```bash
ledge list --feed claude-code      # notes on this feed, with [done/total]
ledge get "$ID"                    # the note's text
ledge get "$ID" --json             # id, title, tasks, state
```

`ledge get --json` is the reliable way to see which tasks exist and which are
done before deciding what to tick.

## When the task is finished

Leave the note. Do not archive it and do not delete it — the user decides what
happens to their own notes. If it is genuinely finished and they asked for it to
be filed away:

```bash
ledge set "$ID" --archive
```

## What not to do

- **Do not write every step.** The point is a note they can glance at, not a
  transcript. A tick when something completes, and an append when something
  surprising happens, is the right rate. If you find yourself appending more
  than a handful of times, you are writing a log, not a feed.
- **Do not rewrite the note.** There is no command to replace the body, on
  purpose: the user may be typing in it at the same time.
- **Do not invent a note.** If `ledge` says no note matches, ask which one
  rather than creating a second one with a similar name.
