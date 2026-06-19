# local-whisper

A fast, fully-local speech-to-text dictation tool for macOS with voice commands, powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). No subscriptions, no cloud — just local transcription optimized for Apple Silicon.

Hold **Right Cmd**, speak, release — text appears at your cursor.

## Features

- **Hold-to-dictate**: Hold a modifier key to record, release to transcribe and insert
- **Voice commands**: Say "voice command note buy coffee" to save a note, "voice command open app Safari" to launch apps, and more — fully customizable
- **Live preview** (off by default): Optional rough partial transcription in the overlay while you speak — a liveness indicator, toggle on from the menu bar
- **Recording indicator**: Audio level meter (bars that move with your voice, flat if the mic is dead) and elapsed timer in the overlay
- **Multi-language**: English, Chinese (Simplified), and auto-detect with preferred-language fallback
- **App-aware processing**: Auto-capitalizes in most apps, skips in terminals and code editors
- **LLM refinement** (optional): Clean up dictated text with a local LLM via [Ollama](https://ollama.com) — fixes punctuation, removes filler words, formats numbered lists
- **Text post-processing**: Remove filler words (um, uh, hmm), clean whitespace
- **Custom vocabulary**: Provide a prompt file to improve recognition of domain-specific terms
- **Auto-stop on silence**: Automatically stops recording after 3 seconds of silence
- **Menu bar**: Waveform icon shows recording status (turns red), click for settings and recent dictations
- **Themes**: Three overlay themes (Frosted Light, Warm Paper, Soft Dark), switchable from the menu bar
- **Configurable sound**: Pick the completion sound — or turn it off — from the menu bar
- **Recent dictations**: View and re-paste your last 10 dictations from the menu bar
- **Fully local**: All processing on-device via whisper.cpp — nothing leaves your machine

## Voice Commands

Voice commands turn dictation into actions. All commands start with **"voice command"** to prevent false matches on normal speech.

| Say | What happens |
|-----|-------------|
| "voice command note buy coffee" | Saves to `~/whisper_notes.md` |
| "voice command remind call mom" | Creates a Reminder in the Reminders app |
| "voice command open app Safari" | Launches or focuses an app |
| "voice command copy" | Fires Cmd+C |
| "voice command paste" | Fires Cmd+V |
| "voice command select all" | Fires Cmd+A |
| "voice command undo" | Fires Cmd+Z |
| "voice command cancel" | Discards the current dictation (works mid-sentence) |

Voice commands are fully customizable — edit `~/.hammerspoon/local_whisper_actions.lua` to add your own. The config auto-reloads when you save.

For a full guide on writing custom commands, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## Requirements

- macOS (Apple Silicon recommended — tested on M4)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/luisalima/local-whisper.git && cd local-whisper && ./install.sh
```

The installer handles everything: Homebrew dependencies, building whisper.cpp, downloading models, and setting up Hammerspoon. It then runs `setup.sh` which walks you through choosing your trigger key, microphone, and granting permissions.

To change the trigger key or re-run setup later:

```bash
./setup.sh
```

<details>
<summary>Manual install (if you prefer)</summary>

```bash
# 1. Dependencies
brew install ffmpeg cmake git
brew install --cask hammerspoon

# 2. Build whisper.cpp
cd ~
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build -j --config Release

# 3. Download model (~1.5 GB)
./models/download-ggml-model.sh medium

# 4. Optional: download tiny model for faster live preview
./models/download-ggml-model.sh tiny

# 5. Copy Hammerspoon config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
```

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon config, `~/.local-whisper/` settings, and temp files. Optionally removes `~/whisper.cpp`. Does not uninstall Homebrew packages.

## Setup

### Permissions (System Settings > Privacy & Security)

| App | Permission |
|-----|-----------|
| Hammerspoon | Accessibility, Microphone |
| Terminal (or your terminal app) | Accessibility (for `hs` CLI) |

### Hammerspoon CLI

Open Hammerspoon console and run once:

```lua
hs.ipc.cliInstall()
```

This installs the `hs` command-line tool used for IPC.

### Audio device

The default `:default` uses your system input device — this is recommended as it survives dock/undock and audio device changes. To use a specific device, find its index:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Then update `AUDIO_DEVICE` in `~/.hammerspoon/init.lua` (e.g., `:0`, `:1`).

## Menu bar

A waveform icon in the menu bar shows recording status (turns red when recording). Click it to:

- See current language, model, output mode, enter mode, and LLM refine status
- Click any setting to cycle it
- Toggle the **live preview** while recording (off by default)
- Switch the overlay **theme** (Frosted Light / Warm Paper / Soft Dark)
- Change the **loading icon** shown while transcribing (4 styles)
- Change the **completion sound** (or turn it off)
- View and re-paste recent dictations
- Open the settings overlay
- Reload voice commands
- Emergency stop

All settings are accessible from the menu bar — no keyboard shortcuts needed.

## Settings & customization (user guide)

Day-to-day settings live in the **menu bar** (click the waveform icon) and on the
**overlay** itself (click a chip to cycle it). Everything else is a small text
file in `~/.local-whisper/`.

### Quick reference

| Setting | What it does | Where to change it | Values | Default |
|---|---|---|---|---|
| **Language** | Transcription language | Menu bar / overlay `lang` chip | `EN`, `ZH`, `auto` | `ZH` |
| **Model** | Whisper model for the final transcription | Menu bar / overlay `model` chip | any model in `~/whisper.cpp/models/` | `medium` |
| **Output** | How text is inserted | Menu bar / overlay `output` chip | `paste`, `type` | `paste` |
| **Enter after insert** | Press Return after inserting | Menu bar / overlay `⏎` chip | on / off | off |
| **Live preview** | Rough partial text in the overlay while recording | Menu bar → *Live preview* | on / off | off |
| **LLM refine** | Clean up text with a local LLM (needs Ollama) | Menu bar / overlay `refine` chip | on / off | off |
| **Theme** | Overlay look | Menu bar → *Theme* | Frosted Light · Warm Paper · Soft Dark | Frosted Light |
| **Loading icon** | Spinner style shown while transcribing | Menu bar → *Loading icon* | Bouncing dots · Comet ring · Orbit dots · Pulse ring | Bouncing dots |
| **Done sound** | Sound after text is inserted | Menu bar → *Done sound* | any macOS system sound, or Off | Glass |
| **Preferred languages** | Languages kept in `auto` mode | `~/.local-whisper/preferred_langs` | comma list, e.g. `en,zh` | `en,zh` |
| **Custom vocabulary** | Bias whisper toward terms / a script | `~/.local-whisper/prompt` | free text | (empty) |
| **Trigger key** | Hold-to-dictate key | `./setup.sh`, or `TRIGGER_KEY` in `init.lua` | `rightCmd`, `rightAlt`, `rightCtrl` | `rightCmd` |
| **Microphone** | Input device | `./setup.sh`, or `AUDIO_DEVICE` in `init.lua` | `:default`, `:0`, `:1`… | `:default` |
| **Auto-stop silence** | Stop after N seconds of silence | constants in `init.lua` | seconds / dB | 3 s / −40 dB |
| **Voice commands** | Spoken actions | `~/.hammerspoon/local_whisper_actions.lua` | Lua hooks | examples preinstalled |

> **Reloading:** files in `~/.local-whisper/` are read on every dictation — no
> reload needed. After editing `init.lua`, reload Hammerspoon (menu bar icon →
> *Reload Config*). The voice-commands file auto-reloads on save.

### The overlay

While recording, a panel appears at the **bottom-center** of the screen with an
audio **level meter**, the elapsed timer, and a row of clickable **chips**
(language, output, ⏎, model, refine). Click a chip to cycle that setting; the
toggle chips (⏎, refine) fill with the accent color when on. Click the empty
panel to **pin** it open; click **✕** to cancel.

The **level meter** (5 bars) shows that your microphone is actually being heard:
the bars rise and fall with your voice, and stay **flat** when there's no input —
so if your input device is broken or muted, you'll see flat bars instead of false
reassurance. (The level is sampled about once a second, so it reacts with a short
lag.)

After you release the key, the meter is replaced by a **loading spinner** in the
same spot (same red, so it reads as one motion) while it transcribes; then the
text drops into your input box and the overlay closes. In this mode the panel is
a compact single row — no wasted space. Pick the spinner style from the menu bar
→ **Loading icon** (Bouncing dots, Comet ring, Orbit dots, Pulse ring).

### Live preview

Off by default. The **Live preview** toggle (menu bar) controls how much the
overlay tells you while it works:

- **Off (default):** the visual-only experience above — level meter while
  recording, spinner while transcribing, then the text appears in your input box.
  Nothing is shown in the overlay itself.
- **On:** the overlay also shows a rough, running transcription while you talk,
  plus `Transcribing…` / `Refining…` status and the final text. This is only a
  *liveness indicator*, **not** the text you'll get — it uses the fastest,
  least-accurate model (`tiny`), refreshes every couple of seconds, and is
  **thrown away**: the text you actually receive is re-transcribed from scratch
  with your chosen model (`medium`) when you release the key.

It's off by default because on a fast machine the final result lands in a few
seconds anyway, and a laggy, wrong preview tends to distract more than it helps.
Errors are always shown as text, in either mode. Stored in
`~/.local-whisper/preview` (`on` / `off`).

### Cancel a dictation

Changed your mind mid-sentence, or don't want what you just said? Press **Esc**
(or click **✕**) — the dictation is discarded and **nothing is inserted**. It
works both while recording *and* during the few seconds of transcription after
you release the key. When you're not dictating, Esc behaves normally.

(The spoken "voice command cancel" still works too, but Esc is more reliable.)

### Themes

Switch from the menu bar (**Theme**). Three options cycle in order:

- **Frosted Light** — translucent light, macOS-native feel (default)
- **Warm Paper** — warm off-white with an orange accent
- **Soft Dark** — soft dark slate (not pure black)

Stored in `~/.local-whisper/theme`.

### Completion sound

The sound played once text is inserted. Menu bar → **Done sound** lists the macOS
system sounds plus **Off**; picking one previews it and saves the choice. Stored
in `~/.local-whisper/sound` (a sound name, or `off`). The start/stop cues remain
`Pop` / `Tink`.

### Simplified Chinese

This setup is tuned for Simplified Chinese:

- Set **Language** to `ZH` for the most reliable result — `auto` works but is slower.
- Whisper mixes Traditional and Simplified output. `~/.local-whisper/prompt` is
  seeded with a Simplified-Chinese sentence to bias the output toward Simplified.
  Occasional Traditional characters are a model limitation; see
  [MODIFICATIONS.md](MODIFICATIONS.md) for a 100%-Simplified OpenCC option.
- For better Chinese accuracy at the cost of speed, download a larger model:
  `bash ~/whisper.cpp/models/download-ggml-model.sh large-v3`, then pick it from
  the menu bar.

## Custom vocabulary prompt

Create `~/.local-whisper/prompt` with terms whisper should recognize better:

```
Claude, Hammerspoon, whisper.cpp, ffmpeg, macOS, Lua, Anthropic
```

This is passed as `--prompt` to whisper-cli for both partial and final transcription. Adding your voice command trigger words here improves recognition.

## LLM refinement (optional)

If you have [Ollama](https://ollama.com) installed, you can enable LLM-powered text cleanup. After transcription, the text is sent to a local LLM that fixes punctuation, removes filler words, and formats numbered lists — all on-device.

1. Install Ollama: `brew install ollama`
2. Pull a model: `ollama pull gemma3:4b` (small, fast, good at text cleanup)
3. Start Ollama: `ollama serve` (or `brew services start ollama`)
4. Toggle in the menu bar or click **refine** in the overlay

Refinement only runs on text longer than 50 characters. Short dictations are inserted as-is.

### Customizing refinement

| File | What it does |
|------|-------------|
| `~/.local-whisper/refine` | ON/OFF state (also togglable from menu bar / overlay) |
| `~/.local-whisper/refine_model` | Ollama model to use (default: `gemma3:4b`) |
| `~/.local-whisper/refine_prompt` | Custom instructions for the LLM |

## Faster live preview

By default, partial transcription uses the same model as final transcription. For faster live preview, download a smaller model:

```bash
cd ~/whisper.cpp/models
./download-ggml-model.sh tiny
```

The system automatically picks the smallest available model (tiny > base > small) for partials while keeping your chosen model for the final transcription.

## App-aware text processing

Post-processing adapts to the frontmost application when you start recording:

- **Terminals** (Terminal, iTerm2, Warp): skips auto-capitalize (commands are lowercase)
- **Code editors** (VS Code, Xcode, Zed, Sublime Text): skips auto-capitalize
- **Everything else**: auto-capitalizes first letter, removes filler words

The active app is also available in voice command hooks as `ctx.appName` and `ctx.appBundleID`.

## Writing custom voice commands

Edit `~/.hammerspoon/local_whisper_actions.lua` to add your own commands. The file returns a table with hooks that run on each dictation:

```lua
return {
    beforeInsert = function(ctx)
        -- Match and handle commands here
    end,
    actions = { },
    afterInsert = function(ctx)
        -- Post-insertion logic (logging, etc.)
    end,
}
```

### Hook context

| Field / Method | Description |
|---------------|-------------|
| `ctx.text` | Current text (mutable via `ctx:setText()`) |
| `ctx.textLower` | Lowercase version for case-insensitive matching |
| `ctx.originalText` | Original transcription (immutable) |
| `ctx.appName` | App name where dictation started (e.g. "Safari") |
| `ctx.appBundleID` | Bundle ID (e.g. "com.apple.Safari") |
| `ctx:setText(text)` | Replace text before insertion |
| `ctx:disableInsert()` | Skip cursor insertion (for command-only actions) |
| `ctx:appendToFile(path, line)` | Append a line to a file (creates parent dirs) |
| `ctx:launchApp("Safari")` | Launch or focus an app |
| `ctx:runShell("cmd", input)` | Run a shell command with optional stdin |
| `ctx:keystroke({"cmd"}, "a")` | Fire a keystroke |
| `ctx:notify("msg")` | Show a notification |
| `ctx.handled` | Set to `true` to skip remaining actions |

The config auto-reloads when you save the file. For more patterns and examples, see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## How it works

```
Modifier key hold/release (detected by Hammerspoon eventtap)
  → ffmpeg records chunked WAV segments (1s each)
  → Partial transcription loop: concat latest chunks → whisper-cli (tiny model)
  → On release: concat all chunks → final whisper-cli transcription (chosen model)
  → Post-processing: remove fillers, capitalize, app-aware adjustments
  → Optional LLM refinement via Ollama (punctuation, formatting, cleanup)
  → Voice command hooks: beforeInsert → actions → text insertion → afterInsert
  → Text inserted at cursor via paste (Cmd+V) or keystroke
```

## Auto-stop on silence

Recording automatically stops after 3 consecutive seconds of silence (< -40 dB). This is useful for hands-free dictation. Configure thresholds in `init.lua`:

```lua
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40
```

## Troubleshooting

- **No transcription output**: Check `$TMPDIR/whisper-dictate/whisper-dictate.log` for errors (run `echo $TMPDIR` to find the path)
- **ffmpeg exits immediately (code 251)**: `AUDIO_DEVICE` is missing the colon prefix — use `:0` not `0`. The `:` tells avfoundation it's an audio device.
- **Wrong microphone**: Run `ffmpeg -f avfoundation -list_devices true -i ""` and update `AUDIO_DEVICE` in init.lua (or use `:default`)
- **Trigger key does nothing**: Accessibility permission may need toggling. Go to System Settings > Privacy & Security > Accessibility, toggle Hammerspoon **OFF then ON**, then run `hs.reload()` in the Hammerspoon console
- **External keyboard mapping**: Some keyboards (e.g., Logitech MX Keys) send non-standard modifier flags. Try different `TRIGGER_KEY` values (`rightAlt`, `rightCmd`, `rightCtrl`) in init.lua
- **`hs` command not found**: Run `hs.ipc.cliInstall()` in Hammerspoon console
- **Voice commands not triggering**: Check the log to see what whisper transcribed — add command words to `~/.local-whisper/prompt`
- **Overlay not appearing**: Hammerspoon may need Accessibility permission re-granted after updates

## Disclaimer

This project was **vibe-coded** — built quickly with AI assistance for personal use. It works on my machine (M4 MacBook Pro), it might work on yours. PRs and issues welcome.

## License

[MIT](LICENSE)
