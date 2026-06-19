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
- **Transcribing:** a rotating-arc **loading spinner** instead of status text.
- **Done:** the text goes straight into the input box and the overlay closes —
  no result is shown in the overlay.

With preview **on**, the old verbose text behavior is kept (partial transcript,
status strings, lingering result). Errors are always shown as text in both modes.

Implementation notes:
- New canvas elements: 5 meter bars (`EL.meter`+0..4) and an `arc` spinner
  (`EL.spinner`); `EL` indices updated. `startRecordingIndicator` animates the
  meter; `startSpinner`/`stopSpinner` drive the arc, with `stopSpinner`
  forward-declared and called from `hideOverlay`/`forceHideOverlay` so every
  teardown path stops the timer.
- Meter geometry/state are grouped into `METER` / `anim` **tables** rather than
  separate locals: the init.lua main chunk is near Lua's 200-locals-per-function
  cap, and adding ~11 separate locals pushed it over (reload failed at load time
  and took out the `hs` IPC port until a full Hammerspoon restart).

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

Ideas not yet built are tracked in [FEATURES.md](FEATURES.md).
