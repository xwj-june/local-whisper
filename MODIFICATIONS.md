# Local modifications

This is a personal fork of [luisalima/local-whisper](https://github.com/luisalima/local-whisper),
cloned and customized for Simplified-Chinese dictation. The original author's
repo is kept as the `upstream` remote so future fixes can be pulled in.

A full security audit of the upstream code was performed before installing
(no external network calls except an optional local Ollama; no telemetry;
permissions used only as described).

## Code changes (tracked in this repo)

### `hammerspoon/init.lua` — language cycle: Chinese in, Portuguese out

The upstream tool only cycles `en → pt → auto`. Changed to `en → zh → auto`
so Chinese can be locked directly (faster + more reliable than `auto`, which
re-transcribes as English when the detected language isn't in `preferred_langs`).

- `getLang()` — allowed languages changed from `en/pt/auto` to `en/zh/auto`.
- `cycleLang()` — cycle table changed from `{ en=pt, pt=auto, auto=en }`
  to `{ en=zh, zh=auto, auto=en }`.

### `hammerspoon/init.lua` — overlay redesign + selectable themes

Reworked the dictation overlay (`createOverlay` / `refreshOverlayLabels`):

- **Position:** moved from bottom-right to **bottom-center** of the screen.
- **Three themes** (`THEMES` table), switchable from the menu bar (**Theme:**
  item, cycles Frosted Light → Warm Paper → Soft Dark). Stored in
  `~/.local-whisper/theme`; default `light`. (Canvas can't do real backdrop
  blur, so the frosted look is a semi-transparent solid fill.)
- **New toggle style:** settings are now rounded "chips" — toggle chips
  (`enter`/`refine`) fill with the accent color when ON and go ghost when OFF;
  value chips (`lang`/`output`/`model`) show their current value. Removed the
  old hover-to-recolor behavior (state is now always visible from the fill).
- Added `getTheme()` / `cycleTheme()` helpers.

### `hammerspoon/init.lua` — configurable completion sound

The "text inserted" sound was hardcoded to `Glass.aiff`. Made it configurable:

- Stored in `~/.local-whisper/sound` as a macOS system-sound name
  (e.g. `Hero`) or `off`; default `Glass`.
- Menu bar gains a **Done sound** submenu listing the system sounds + Off;
  picking one previews it and saves the choice.
- Added `getSound()` / `setSound()` / `playDoneSound()`; `finishInsertion`
  now calls `playDoneSound()`.
- (Start/stop sounds remain `Pop` / `Tink`, not yet configurable.)

### `hammerspoon/init.lua` — cancel a dictation (Esc / ✕)

Added a way to discard the current dictation so nothing gets inserted:

- **Esc** (or the overlay **✕**) cancels — works both while recording and during
  the post-release transcription window. A global `keyDown` eventtap consumes Esc
  only while a dictation is active (recording, or a non-pinned overlay is up);
  otherwise Esc passes through to the focused app.
- Added a `dictationCancelled` flag (reset in `startRecording`) checked in
  `insertTranscribedText` / `finishInsertion`, plus `cancelDictation()` which
  tears down recording/transcription and kills in-flight `whisper-cli`.
- The ✕ button now routes to `cancelDictation()` — previously it only dismissed
  the overlay after release, so the in-flight transcription still inserted.

### `hammerspoon/init.lua` — live preview off by default, toggleable

The rough `tiny`-model preview shown while recording used to always run. It's a
liveness indicator, not the final text (which is re-transcribed with the chosen
model on release), so it's now opt-in:

- **Default off.** `startRecording` only starts the partial-transcribe timer
  when preview is on, saving the per-2s `tiny` run otherwise.
- New **Live preview: ON/OFF** menu-bar toggle (next to *Enter after insert*).
- Stored in `~/.local-whisper/preview` (`on`/`off`); added `getPreview()` /
  `setPreview()`.

### `hammerspoon/init.lua` — minimal overlay: level meter + loading spinner

The overlay's textual states (`Listening...` / `Transcribing...` / `Refining...`
and the lingering final-result text) are now coupled to the **Live preview**
toggle. With preview **off** (default) the overlay is purely visual:

- **Recording:** an audio **level meter** (5 bars) replaces the old single red
  dot. Bar height tracks the real mic level measured by `checkSilence` (dB →
  0..1), so a dead/silent input device reads as flat bars — confirming the mic
  is actually being heard. Bars animate via a per-bar traveling wave scaled by
  that level. (~1 s latency, since the level comes from the 1 s silence-check.)
- **Transcribing:** a **loading spinner** in the *same top-right slot* as the
  meter (the meter is hidden by then) — no separate area for it. The spinner
  style is selectable from a **Loading icon** menu submenu (with a live preview
  on pick): **Bouncing dots** (default), **Comet ring**, **Orbit dots**, **Pulse
  ring**. Stored in `~/.local-whisper/spinner`; the spinner is drawn in the same
  red as the meter bars so recording → transcribing reads as one motion.
- **Done:** the text goes straight into the input box and the overlay closes —
  no result is shown in the overlay.

Because minimal mode shows no transcript/result text, its panel is **compact**
(single chip row, ~40px) instead of the tall 92px verbose panel — no empty space
reserved at the bottom. Errors in minimal mode use a macOS **notification**
(there's no text area); verbose mode shows them inline.

With preview **on**, the old verbose text behavior is kept (tall panel, partial
transcript, status strings, lingering result).

Implementation notes:
- Canvas elements: 5 meter bars (`EL.meter`+0..4) plus the spinner's elements,
  which vary by style (3 dots / 8 dots / 2 rings / track+arc) and are appended
  after the close button; their range is tracked at runtime in
  `anim.spinFirst`/`spinCount` rather than fixed `EL` indices.
  `startRecordingIndicator` animates the meter; `startSpinner`/`stopSpinner`
  drive the spinner (both forward-declared — `stopSpinner` called from
  `hideOverlay`/`forceHideOverlay` so every teardown path stops the timer,
  `startSpinner` from the menu pick-preview).
- Meter/spinner geometry + state are grouped into `METER` / `anim` **tables**
  rather than separate locals: the init.lua main chunk is near Lua's
  200-locals-per-function cap, and adding many separate locals pushed it over
  (reload failed at load time and took out the `hs` IPC port until a full
  Hammerspoon restart). `anim` must be declared **before** `createOverlay`, which
  references it — a later declaration makes it a nil global at overlay-build time.

### `hammerspoon/init.lua` — dictation stats

Tracks how much you dictate and shows it in a stats window. Full design in
[docs/STATS_DESIGN.md](docs/STATS_DESIGN.md). Summary:

- **Counting:** hybrid word count — each CJK character = 1, each run of ASCII
  word chars = 1 (`我在用 Claude Code` → zh 3 + en 2 = 5). Recorded only when text
  is actually inserted; cancelled/empty dictations count nothing.
- **Storage:** `~/.local-whisper/stats.json`, per-local-day buckets
  (`{words,zh,en,seconds,count}`) + `since`; all-time = sum of days. **Atomic
  write** (temp file + `os.rename`). Corrupt file → start fresh.
- **UI:** menu **Stats…** opens an `hs.webview` dashboard (Today / All-time,
  tabbed 14-day bar chart + 17-week GitHub-style heatmap, secondary stats),
  drawn in the meter red; plus a glance line in the menu.
- All state/functions hang off one **global** `stats` table (like `_whisper` /
  `WhisperActions`) — the 200-locals cap left no room for even one new top-level
  local. Defined before its callers.
- Note: `os.date` rejects the non-portable `%-d`; format no-leading-zero days as
  `os.date("%b ") .. tonumber(os.date("%d"))`.

## Runtime config changes (NOT in this repo — machine-local)

These live in `~/.local-whisper/` and are per-machine user settings, so they
are not version-controlled. Recreate them on a new machine to reproduce the
setup:

```sh
# Lock dictation language to Chinese (menu bar / overlay can still cycle to en/auto)
echo -n "zh" > ~/.local-whisper/lang

# Languages kept when in auto mode (Portuguese removed)
echo -n "en,zh" > ~/.local-whisper/preferred_langs

# Whisper initial prompt — biases output toward Simplified Chinese characters,
# and seeds proper nouns (e.g. "Claude Code") so they transcribe correctly.
# (Whisper is not an LLM; the bias comes from the words present here, not the
#  instruction. Add high-frequency proper nouns after the colon, separated by 、.
#  On silent/empty audio this text may occasionally leak into output — keep it
#  short if that happens.)
printf '以下是简体中文的对话记录，请将语音转写为规范的简体中文。可能出现的专有名词：Claude Code。' > ~/.local-whisper/prompt
```

## Setup facts (for reference)

- Active model: `ggml-medium.bin` (~1.4 GB, Whisper medium multilingual),
  stored at `~/whisper.cpp/models/`. Downloaded once, reused locally; never
  re-downloaded. Switchable from the menu bar.
- `tiny` model (~74 MB) is used only for the live preview while holding the key.
- Hardware: Apple M4 / 32 GB. Release-to-result latency ~3–5 s, dominated by
  per-dictation model load + inference.

## Possible future changes

Backlog of ideas not yet built lives in **bd** (the [beads](https://github.com/steveyegge/beads)
issue tracker). Run `bd ready` for pickable work, `bd list --all` for everything.
