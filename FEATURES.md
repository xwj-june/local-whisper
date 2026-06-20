# Feature list / backlog

The active **backlog now lives in bd** (the [beads](https://github.com/steveyegge/beads)
issue tracker), not in this file. Browse it from the repo root:

```bash
bd ready          # unblocked work, ready to pick up
bd list           # open + in-progress issues
bd list --all     # everything, including closed
bd show <id>      # full detail (why + effort) for one issue
```

Add an idea with:

```bash
bd create "Title" -t feature -p <0-4> --description="why + rough effort"
```

Effort convention (write it into the description): **low** (a small contained
edit) · **medium** (a function + some wiring) · **high** (architecture /
lifecycle / a new dependency).

The *Shipped* list below stays as a human-readable changelog; implementation
details live in [MODIFICATIONS.md](MODIFICATIONS.md).

## Ideas migrated to bd (snapshot 2026-06-20)

> Frozen snapshot of what moved into bd. **Manage these in bd — don't edit here.**
> Run `bd show <id>` for the full why/effort/notes.

| bd id        | Idea                                                              | Effort  |
|--------------|------------------------------------------------------------------|---------|
| `lw-2bbb2dd4` | Persistent `whisper-server` — kill per-dictation reload latency  | high    |
| `lw-30cffadd` | OpenCC post-processing — guaranteed Simplified Chinese           | low–med |
| `lw-405345d5` | Configurable refine via remote / OpenAI-compatible API          | medium  |
| `lw-339d7487` | Configurable start/stop sounds                                   | low     |
| `lw-d827d2aa` | Bake zh / Simplified defaults into `init.lua`                    | low     |
| `lw-6c74bfbd` | Easy custom-vocab dictionary + fuzzy snap-to-term correction    | —       |

## Shipped

See [MODIFICATIONS.md](MODIFICATIONS.md) for details.

- [x] Simplified-Chinese dictation (lock `zh`, drop `pt`, Simplified prompt bias)
- [x] Overlay redesign — bottom-center, chip toggles, 3 selectable themes
- [x] Configurable completion sound (menu bar submenu)
- [x] Esc / ✕ to cancel a dictation (insert nothing)
- [x] Live preview off by default, toggleable from the menu bar
- [x] Minimal overlay: audio level meter while recording + loading spinner while transcribing
- [x] Compact minimal panel (spinner reuses meter slot, no wasted space)
- [x] Selectable loading icon — 4 spinner styles from the menu (default bouncing dots)
- [x] Dictation stats — words (today/all-time), time, count; `Stats…` webview with 14-day bar + 17-week heatmap ([spec](docs/STATS_DESIGN.md))
