# kghostty — a Ghostty-style terminal in pure Krypton

Goal: what Ghostty is (fast, modern, native terminal) but written in Krypton —
native compile, no C in the loop, GC runtime. First target: **Hyprland/Wayland on
Linux**. macOS/Windows follow the same layering.

## Ghostty's architecture → Krypton mapping

Ghostty (Zig) is cleanly layered: a platform-independent **terminal core**, a
**renderer** that turns terminal state into pixels, and an **app-runtime (apprt)**
that owns the OS window + input. Krypton already has most of these as shipping
code in **stem** and the **k:wayland** stdlib:

| Ghostty `src/` | Responsibility | Krypton today |
|---|---|---|
| `terminal/` | VT parser + screen/grid state machine | **stem `term.k`** (gridNew/gridFeed/gridRender) ✅ |
| `termio/` | PTY read/write loop | **stem `pty.k`** + linux_x86 pty/fd builtins ✅ |
| `config/` | config file parse + settings | **stem `config.k`** (stem.conf) ✅ |
| `apprt/` | OS window + event loop | **k:wayland** (wlConnect/wlCreateSurface/wlGetXdgSurface/wlCommit) ✅ |
| `renderer/` | terminal state → pixels | **k:wayland fb** (fbFillRect/fbBlitBGRA/fbDrawChar/fbDrawText) — software, ✅ |
| `font/` | glyph rasterization | **k:wayland wlFontLoad** (embedded 8px bitmap font) — minimal ✅; real shaping = future |
| `input/` | keyboard → keybinds → bytes | **k:wayland wlGetKeyboard/wlKeyToKc** → map → write PTY — partial (new glue) |
| `cli/`, `os/`, `terminfo/`, `unicode/` | misc | stdlib / future |
| GPU (Metal/OpenGL) | hardware render | **objk/FFI to OpenGL/Vulkan** — FUTURE, macOS-objc-style FFI; not needed for MVP |

**The hard 80% already exists.** stem is a complete headless terminal engine
(real PTY + VT grid); k:wayland is a complete software-rendered windowing layer
(cortex_wl.k proves it — a 918-line Wayland GUI). kghostty = **glue**: host stem's
grid in a k:wayland window.

## On `.objk` / FFI

There are NO `.objk` files in the tree, and `.objk` is not a file format. "objk"
is Krypton's **generic C-FFI** (dylib import + foreign calls; objc/cocoa was its
first client on macOS — see docs/cocoa_design.md). The Linux/Wayland path is pure
syscalls (k:wayland), so kghostty's MVP is **`.k` + `.ks` only**. FFI/objk enters
ONLY if/when we add a GPU renderer (OpenGL/Vulkan/Metal) — a later, optional,
per-platform track, mirroring Ghostty's GPU layer.

## MVP — windowed terminal on Hyprland

Reuse, don't rewrite. The MVP is cortex_wl.k's window+loop pattern, rendering the
terminal grid instead of a file list:

```
connect Wayland (wlConnect) → create surface + xdg toplevel
spawn shell on PTY (stem pty.k, shell from stem.conf)
font = wlFontLoad()
loop:
  poll Wayland (keyboard) + PTY (fdRead, nonblocking)
  keystrokes → bytes → fdWrite(pty)              [input/]
  pty output → gridFeed(state, bytes, cols, rows) [terminal/]
  on dirty: clear fb; for each grid cell fbDrawChar(...) ; wlCommit  [renderer/]
  on resize: recompute cols=fbW/8, rows=fbH/16; ptySetSize           [apprt/]
```

cols/rows derive from window px ÷ cell size (fbTextWidth = len*8, 8x16 cells).

## Module layout (this dir)

- `terminal.k`  — re-exports/wraps stem's term.k + pty.k engine (or `import` stem).
- `config.k`    — kghostty config (extends stem.conf: + font_size, theme, padding).
- `render.k`    — grid → framebuffer (fbDrawChar per cell, colors, cursor).
- `input.k`     — Wayland keysym → terminal byte sequences (arrows, ctrl, etc).
- `window.k`    — k:wayland surface lifecycle (connect/create/configure/commit).
- `kghostty.ks` — entry: parse argv, load config, wire window+engine+render loop.

(MVP can collapse these into one `kghostty.ks` first, split later — same as stem
started as run.k then grew.)

## What's genuinely NEW vs reused

- REUSED: VT/grid (stem term.k), PTY (stem pty.k), config (stem config.k),
  Wayland window + framebuffer + font + keyboard (k:wayland).
- NEW (the glue): grid-cell → fb draw loop with colors+cursor, keysym→bytes map,
  resize→cols/rows→ptySetSize, the event-pump tying Wayland + PTY together.
- FUTURE (Ghostty parity, big): real font shaping (ligatures/fallback), GPU
  renderer via objk/FFI, tabs/splits, ligatures, image protocol, theme engine.

## Honest scope

Ghostty is years of work + GPU + cross-platform. kghostty's **MVP** (a real
Hyprland window running your shell, software-rendered) is achievable in a focused
build (~cortex_wl.k size, days not months) because stem + k:wayland already exist.
Full Ghostty parity is a long arc; this doc is the blueprint + reuse map so each
piece lands against a clear target.
