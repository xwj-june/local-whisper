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

## Runtime config changes (NOT in this repo — machine-local)

These live in `~/.local-whisper/` and are per-machine user settings, so they
are not version-controlled. Recreate them on a new machine to reproduce the
setup:

```sh
# Lock dictation language to Chinese (menu bar / overlay can still cycle to en/auto)
echo -n "zh" > ~/.local-whisper/lang

# Languages kept when in auto mode (Portuguese removed)
echo -n "en,zh" > ~/.local-whisper/preferred_langs

# Whisper initial prompt — biases output toward Simplified Chinese characters.
# (Whisper is not an LLM; the bias comes from the characters present here, not
#  the instruction. On silent/empty audio this text may occasionally leak into
#  output — shorten it if that happens.)
printf '以下是简体中文的对话记录，请将语音转写为规范的简体中文。' > ~/.local-whisper/prompt
```

## Setup facts (for reference)

- Active model: `ggml-medium.bin` (~1.4 GB, Whisper medium multilingual),
  stored at `~/whisper.cpp/models/`. Downloaded once, reused locally; never
  re-downloaded. Switchable from the menu bar.
- `tiny` model (~74 MB) is used only for the live preview while holding the key.
- Hardware: Apple M4 / 32 GB. Release-to-result latency ~3–5 s, dominated by
  per-dictation model load + inference.

## Possible future changes (discussed, not yet done)

- **Persistent `whisper-server`** to eliminate the per-dictation model reload
  (~1–2 s floor). `whisper-server` binary already exists in the build. Trade-off:
  needs process-lifecycle management and complicates model switching
  (one server = one model; the tiny-preview optimization would need a 2nd server).
- **Bake the zh/Simplified defaults into `init.lua`** so a fresh install starts
  in Chinese without the runtime-config steps above.
- **OpenCC post-processing** for a 100% Simplified guarantee (vs. the current
  prompt-based bias).
