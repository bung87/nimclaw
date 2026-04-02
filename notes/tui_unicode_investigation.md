# TUI Unicode Emoji Investigation

## Problem
After typing input in the TUI, the lobster emoji `🦞` disappeared or got corrupted. Additionally, copy-pasting Chinese text was silently ignored.

## Root Cause
`illwill` (the original TUI library) has two fatal limitations:

1. **Differential renderer (`displayDiff`) corrupts wide characters**: it stores one Unicode **rune** per grid cell and advances the terminal cursor by 1 cell. Emoji like `🦞` occupy **2 terminal columns**, so the cursor desynchronizes and overwrites part of the character.
2. **No UTF-8 input parsing**: `getKey()` reads **one byte at a time** and maps it to a `Key` enum that only covers ASCII (`0`–`127`). Multi-byte UTF-8 sequences (Chinese characters) are discarded as `Key.None` before the application ever sees them.

## Libraries Evaluated

| Library | Pure Nim? | Wide char support? | Verdict |
|---------|-----------|-------------------|---------|
| **textalot** | Yes | ✅ Correct | Properly parses UTF-8 runes from stdin and handles terminal output as continuous strings |
| **celina** | Yes | ⚠️ Partial | Buffer model tracks wide chars, but diff renderer still corrupts them |
| **illwave** | Yes | ⚠️ Partial | Fork of illwill; single-arg `display()` full-redraws (works), but diff mode has same bug |
| **termbox** | No (C lib) | ✅ Correct | Native `uint32` cells, but Nim wrapper hardcodes `defined(Linux)` only — won't compile on macOS |
| **notcurses** | No (C lib) | ✅ Correct | Industry-leading Unicode support, but heavy C dependency and steeper plane-based API |

## Fix Applied

Migrated the TUI from `illwill` to `textalot`:

- `src/nimclaw/tui/core.nim` — rewritten using `textalot` APIs (`drawText`, `drawRectangle`, `readEvent`, etc.)
- `nimclaw.nimble` — replaced `requires "illwill >= 0.4.0"` with `requires "textalot >= 0.1.0"`

Key changes:
- Input handling now reads full UTF-8 runes, so copy-paste of Chinese (and any Unicode) works
- Rendering uses `textalot`'s global back-buffer with full-frame redraws, avoiding the wide-char corruption
- Cursor movement and backspace/delete operate on rune boundaries instead of byte boundaries
- `wrapText` was updated to wrap CJK text that contains no spaces

## Files Changed
- `src/nimclaw/tui/core.nim`
- `nimclaw.nimble`
