# Dictation stats — design

Status: **design / spec** (not yet implemented). Date: 2026-06-19.

Track how much has been dictated — words today, words all-time, total dictation
time — and show it in a small stats window with two switchable charts.

## Goal

Answer, at a glance:
- How many words did I dictate **today**? **All-time**?
- How long have I spent dictating (today / all-time)?
- What does my recent activity look like (last 14 days, and a longer trend)?

Non-goals (for v1): editing/clearing stats from the UI, CSV export, per-app or
per-language dashboards, syncing anywhere. All local.

## Counting rules

### "Words" (the headline metric)

Plain character count over-counts English (every letter) and plain
whitespace-splitting breaks Chinese (no spaces → a whole sentence is one
"word"). So we use a **hybrid count**, the same approach Word/WeChat use for
mixed CJK text:

> **words = (count of CJK characters) + (count of runs of non-CJK word
> characters)**

- Each CJK character (Chinese/Japanese/Korean ideograph) counts as **1**.
- Each maximal run of Latin letters/digits counts as **1** word.
- Punctuation and whitespace are separators, not counted.

Example: `我在用 Claude Code 2` → `我`,`在`,`用` (3 CJK) + `Claude`,`Code`,`2`
(3 runs) = **6 words**.

We also keep the split for display: `zh` = CJK-char count, `en` = non-CJK word
count, `words = zh + en`.

Implementation note (Lua has no Unicode classes): detect CJK by codepoint range
via `utf8.codes`. Primary ranges: CJK Unified Ideographs `0x4E00–0x9FFF`,
Extension A `0x3400–0x4DBF`, plus common kana `0x3040–0x30FF`. Everything else is
scanned with a Lua pattern over runs of `%w` (ASCII letters/digits) — good enough
for English/numbers; accented Latin is rare in this tool's use and may under-count
slightly (acceptable for v1).

### Time

Per dictation, **time = key-release timestamp − recording-start timestamp**
(how long the modifier key was held). Summed per day and all-time.

### What counts as a dictation

A dictation is counted (words + time + 1) **only when text is actually inserted**
at the cursor (`ctx.inserted == true` in `finishInsertion`). Therefore:

- **Cancelled** dictations (Esc / ✕) count for **nothing** — no words, no time,
  no count.
- Empty / hallucination-only results (nothing inserted) count for nothing.
- Voice commands that insert text count; voice commands that only fire an action
  and insert nothing do not.
- Auto-stop-on-silence dictations count normally (they produce inserted text).

## Data model

Stored at `~/.local-whisper/stats.json` (JSON, local only, never uploaded):

```json
{
  "since": "2026-05-28",
  "days": {
    "2026-06-18": { "words": 3120, "zh": 2400, "en": 720, "seconds": 1180, "count": 31 },
    "2026-06-19": { "words": 2418, "zh": 1840, "en": 578, "seconds": 872,  "count": 23 }
  }
}
```

- `days` is keyed by **local** calendar date (`os.date("%Y-%m-%d")` at the moment
  the dictation completes — so a dictation belongs to the day it finished).
- `since` = earliest date we have data for (set on first ever record).
- **All-time totals are computed by summing `days`** (not stored separately), so
  there's no running-total drift. The map is tiny (one entry per active day).
- Derived for the UI: all-time `{words, seconds, count}`; `avg / active day`
  (all-time words ÷ number of day entries); `best day` (max `words` + its date);
  `tracking since` (`since`).

### Recording flow

- Capture `recordingStartTime` (already exists). On key release in
  `stopRecording`, stash the duration (`lastRecordingSeconds = now - start`).
- In `finishInsertion`, after a successful insert, call `recordStats(finalText,
  lastRecordingSeconds)`:
  - compute `zh`, `en`, `words` from `finalText`;
  - `day = os.date("%Y-%m-%d")`;
  - load stats.json, add to `days[day]` (create if missing), set `since` if unset,
    write back.
- Reuse the existing JSON load/save pattern from recent-dictations
  (`hs.json.encode/decode`, atomic-ish overwrite). Keep an in-memory copy loaded
  at startup, mutate in place (avoid the upvalue-reassignment pitfall noted in
  AGENTS.md), and persist on each record.

## UI

### Entry points

- **Menu bar → `Stats…`** opens a stats window.
- The menu also shows a non-clickable glance line near the top, e.g.
  `Today: 2,418 字词` (updates when the menu is rebuilt).

### Stats window

An `hs.webview` window (same pattern as the meeting notepad), rendered from
HTML/CSS generated in Lua with the current numbers injected. It's a **static
snapshot taken when opened** — no live updating needed; closing and reopening
refreshes. Visual language matches the overlay: dark panel, the meter/spinner
**red** accent, monospace figures; the charts use the same "bars + red" motif.

Layout (top to bottom):

1. **Today** (red-accented block) and **All time** (neutral block), side by side.
   Each shows the big **words** figure, a `zh · en` split line, and `time` +
   `dictations` beneath.
2. **Tabbed chart** — two views, one shown at a time (default *14 days*):
   - **14 days** — vertical bar chart, words/day, today's bar highlighted.
   - **Activity** — GitHub-style contribution heatmap (≈17 weeks × 7 days),
     5 intensity buckets by words/day, weekends naturally lighter, `Less→More`
     legend. Both views read the same per-day data.
3. **Secondary stats** row: `avg / active day`, `best day · <date>`,
   `tracking since <date>`.
4. Footer note: "Counts text inserted at the cursor · cancelled dictations
   excluded · stored on this Mac only".

Reference mock (design-approved): the published artifact built during
brainstorming (tabbed bar/heatmap, hybrid word count).

## Edge cases

- **No stats file yet / first run**: treat as empty; window shows zeros and a
  gentle empty state; `since` is set on the first recorded dictation.
- **Day rollover**: attribution is by completion time; a dictation spanning
  midnight lands on the day it finished. Acceptable.
- **Timezone / clock**: uses local time via `os.date`; no UTC bookkeeping.
- **Very old history**: charts only read the recent window (14 days / 17 weeks);
  the full `days` map is retained for all-time totals. No pruning in v1.
- **Corrupt/edited JSON**: on decode failure, log and start fresh (don't crash);
  do not overwrite a backup automatically in v1.
- **Webview availability**: if the window can't be created, fall back to showing
  today's glance via a notification.

## Verification checklist

- Dictate known text in zh, en, and mixed; confirm `words`/`zh`/`en` match the
  rule. E.g. `我在用 Claude Code` → zh=3 (`我`,`在`,`用`), en=2 (`Claude`,`Code`),
  words=5.
- Cancel (Esc and ✕): stats unchanged.
- Empty/silent dictation: stats unchanged.
- Time accumulates roughly equal to hold duration.
- Reopen window across a day boundary: new day bucket appears.
- `stats.json` is valid JSON and reload-safe; deleting it resets cleanly.
- All-time = sum of days; avg/best/since correct.

## Out of scope / later

- Clearing or editing stats from the UI.
- Export (CSV/Markdown).
- Words-per-minute, per-app or per-language breakdowns.
- Weekly/monthly toggles beyond the two charts.
