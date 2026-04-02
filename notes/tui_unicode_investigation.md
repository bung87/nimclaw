# TUI Unicode Emoji Investigation

## Problem
After typing input in the TUI, the lobster emoji `🦞` disappeared or got corrupted.

## Root Cause
`illwill` (the current TUI library) uses a cell-based differential renderer (`displayDiff`). It stores one Unicode **rune** per grid cell and advances the terminal cursor by 1 cell at a time. However, wide characters like `🦞` (emoji) occupy **2 terminal columns** in practice. When the diff renderer moves the cursor cell-by-cell, it desynchronizes from the actual terminal cursor position and overwrites part of the emoji.

## Libraries Evaluated

| Library | Pure Nim? | Wide char support? | Verdict |
|---------|-----------|-------------------|---------|
| **textalot** | Yes | ❌ Same bug | Same architecture as illwill: 1 rune/cell with diff renderer |
| **celina** | Yes | ⚠️ Partial | Buffer model tracks wide chars, but diff renderer still corrupts them |
| **illwave** | Yes | ⚠️ Partial | Fork of illwill; single-arg `display()` always full-redraws (works), but diff mode has same bug |
| **termbox** | No (C lib) | ✅ Correct | Native `uint32` cells, but Nim wrapper hardcodes `defined(Linux)` only — won't compile on macOS |
| **notcurses** | No (C lib) | ✅ Correct | Industry-leading Unicode support, but heavy C dependency and steeper plane-based API |

## Options Considered

1. **Replace with termbox** — Best Unicode support, but macOS incompatible without patching the Nim wrapper.
2. **Replace with notcurses** — Works on macOS, but overkill for a simple chat TUI; requires significant rewrite.
3. **Replace with illwave** — Drop-in illwill fork where `display()` always full-redraws, avoiding the bug.
4. **Disable illwill double-buffering** — One-line fix forcing full redraw every frame. Performance impact is negligible for a chat TUI.

## Fix Applied

Added `setDoubleBuffering(false)` in `src/nimclaw/tui/core.nim`:

```nim
proc newTuiApp*(agentLoop: AgentLoop, cfg: Config): TuiApp =
  illwillInit(fullscreen = true)
  hideCursor()
  setDoubleBuffering(false)  # <-- forces full redraw, terminal handles wide chars correctly
  ...
```

This bypasses the buggy differential renderer and lets the terminal handle multi-column characters correctly.

## Files Changed
- `src/nimclaw/tui/core.nim`
