# Feature list / backlog

Ideas for this fork — things to maybe build later. **Add freely**: drop a new
`- [ ]` item under *Ideas*, with a line or two on *why* and rough *effort*.
Check it off (`- [x]`) or move it to *Shipped* when done. Details of what's
already built live in [MODIFICATIONS.md](MODIFICATIONS.md).

Effort = rough size: **low** (a small contained edit) · **medium** (a function +
some wiring) · **high** (architecture / lifecycle / a new dependency).

## Ideas

- [ ] **Persistent `whisper-server`** — kill the per-dictation model-reload delay
  - Why: removes the ~1–2 s "floor" latency on every dictation (model stays warm
    in memory instead of reloading each time).
  - Effort: **high**. The `whisper-server` binary already exists in the build.
    Needs process lifecycle (start on load, restart on model switch, stop on
    shutdown) and a decision: one server (drop the tiny live-preview speedup) vs.
    two servers (tiny + main warm, ~1.6 GB RAM).

- [ ] **Configurable refine via remote / OpenAI-compatible API**
  - Why: use a remote Ollama or a hosted LLM (OpenAI / Anthropic / Groq /
    OpenRouter) for refine instead of only local Ollama.
  - Effort: **medium**. Make endpoint + model + API key configurable.
  - ⚠️ Privacy: this sends transcribed **text off-device**. Keep any API key in
    `~/.local-whisper/`, never in the repo. Best-privacy option = self-hosted
    remote Ollama (data stays on a box you control).

- [ ] **OpenCC post-processing** — guaranteed Simplified Chinese
  - Why: 100% Simplified output. The current `~/.local-whisper/prompt` is only a
    soft bias, so Traditional characters still leak through.
  - Effort: **low–medium**. `brew install opencc` + a `t2s` conversion step
    before insertion, gated on language = zh.

- [ ] **Configurable start/stop sounds**
  - Why: only the "done" sound is configurable today; start (`Pop`) and stop
    (`Tink`) are still hardcoded.
  - Effort: **low**. Same pattern as the existing "Done sound" submenu.

- [ ] **Bake zh / Simplified defaults into `init.lua`**
  - Why: a fresh install would start in Chinese without the manual runtime-config
    steps documented in MODIFICATIONS.md.
  - Effort: **low**. Change the defaults in `getLang()` / `getPreferredLangs()`
    and seed the prompt.

## Shipped

See [MODIFICATIONS.md](MODIFICATIONS.md) for details.

- [x] Simplified-Chinese dictation (lock `zh`, drop `pt`, Simplified prompt bias)
- [x] Overlay redesign — bottom-center, chip toggles, 3 selectable themes
- [x] Configurable completion sound (menu bar submenu)
- [x] Esc / ✕ to cancel a dictation (insert nothing)
- [x] Live preview off by default, toggleable from the menu bar
- [x] Minimal overlay: audio level meter while recording + loading spinner while transcribing
