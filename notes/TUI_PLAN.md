# Nimclaw TUI Implementation (Complete)

## Overview
Full-screen terminal UI using [illwill](https://github.com/johnnovak/illwill) with help panel and word wrap.

## Current Implementation

```
┌──────────────────────────────────────────────────────────────┐
│ 🦞 Nimclaw          ollama / qwen2.5-coder:7b          ○    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  You:      hello                                             │
│                                                              │
│  🦞:       Hello! How can I help you today?                  │
│                                                              │
│  You:      list files in workspace                           │
│                                                              │
│  🦞:       Here are the files in your workspace:             │
│            - memory/                                         │
│            - skills/                                         │
│            - ...                                             │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ 🦞 _                                               [H:help]  │
└──────────────────────────────────────────────────────────────┘
```

### With Help Panel (Ctrl+H)
```
┌────────────────────────────────────────────┬─────────────────┐
│ 🦞 Nimclaw          ollama / qwen2.5...   │ Keybindings     │
├────────────────────────────────────────────┼─────────────────┤
│                                            │                 │
│  You:      hello                           │ Enter      Send │
│                                            │ ↑/↓      Scroll │
│  🦞:       Hello! How can...               │ PgUp/PgDn Page  │
│                                            │ Ctrl+H    Help  │
│                                            │ Ctrl+L    Clear │
│                                            │ Ctrl+C     Quit │
│                                            │                 │
│                                            │ Provider        │
│                                            │ ollama          │
│                                            │ Model           │
│                                            │ qwen2.5-coder   │
├────────────────────────────────────────────┴─────────────────┤
│ 🦞 _                                               [H:hide]  │
└──────────────────────────────────────────────────────────────┘
```

## Features Implemented

### Layout Components
- ✅ **Header Bar**: Logo (green), provider/model info (cyan), status indicator (●/○)
- ✅ **Chat Area**: Scrollable with word wrap, role indicators (You:/🦞:)
- ✅ **Input Area**: Visual scrolling for long input, underscore cursor
- ✅ **Help Panel**: Toggle with Ctrl+H, shows keybindings and config
- ✅ **Status Indicator**: Yellow ● when generating, green ○ when idle

### Key Bindings
| Key | Action |
|-----|--------|
| `Enter` | Send message |
| `↑/↓` | Scroll chat history |
| `PgUp/PgDn` | Page scroll |
| `Ctrl+H` | Toggle help panel |
| `Ctrl+L` | Clear chat |
| `Ctrl+C` | Quit |

### Visual Features
- ✅ **Role Colors**: User (cyan), Assistant (green), System (yellow), Tool (magenta)
- ✅ **Word Wrap**: Messages wrap to fit screen width
- ✅ **Typing Indicator**: Yellow dot when LLM is generating
- ✅ **Dim Separators**: Header and input separators use {styleDim}
- ✅ **Help Hint**: [H:help]/[H:hide] shown in input area

## Implementation Details

### Module Structure
```
src/nimclaw/
├── tui/
│   └── core.nim          # TUI implementation
├── nimclaw.nim           # Main entry (TUI is default)
└── ...
```

### Key Types
```nim
TuiApp = ref object
  tb: TerminalBuffer       # illwill terminal buffer
  messages: seq[ChatMessage]
  inputBuffer: string      # Full input text
  visualInput: string      # Visible portion
  cursorX: int             # Logical cursor
  visualCursorX: int       # Visible cursor
  scrollOffset: int        # Chat scroll position
  showHelp: bool           # Help panel visible
  isGenerating: bool       # LLM working indicator
```

### Smart Input Scrolling
```nim
proc updateVisualInput(app: TuiApp) =
  # Shows only visible portion, scrolls with cursor
  # Centers cursor when text is longer than screen width
```

### Word Wrap
```nim
proc wrapText(text: string, maxWidth: int): seq[string]
  # Simple word wrap by spaces
  # Preserves message readability
```

## Usage

```bash
# TUI mode (default)
nimclaw agent

# One-shot mode
nimclaw agent --message "hello"

# Other commands unchanged
nimclaw gateway
nimclaw status
```

## Dependencies
```nim
# nimclaw.nimble
requires "illwill >= 0.4.0"
```

## Files
- `src/nimclaw/tui/core.nim` - Full TUI implementation
- `src/nimclaw.nim` - Updated to use TUI as default
- `TUI_PLAN.md` - This document

## Notes
- Terminal is restored on exit (Ctrl+C)
- Non-blocking input allows async LLM calls
- Double buffering for smooth rendering
- Emoji "🦞" displays correctly
