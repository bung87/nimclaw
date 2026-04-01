# Nimclaw TUI Improvement Plan (using illwill)

## Overview
Replace the simple stdin/stdout CLI with a rich terminal UI using [illwill](https://github.com/johnnovak/illwill).

## Prerequisites
```bash
nimble install illwill
```

## Current State
```
🦞 Interactive mode

🦞 You: hello
🦞 Hello! How can I help you today?

🦞 You: exit
```

## Target Design
```
┌─────────────────────────────────────────────────────────────────┐
│ 🦞 PicoClaw 0.1.0          model: qwen2.5-coder:7b  ollama ✓   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  You       hello                                                │
│                                                                 │
│  🦞        Hello! How can I help you today?                     │
│                                                                 │
│  You       list files                                           │
│            └─▶ Tool: list_dir                                   │
│            └─▶ Result: 5 files found                            │
│                                                                 │
│  🦞        Here are the files in your workspace:                │
│            - memory/                                            │
│            - skills/                                            │
│            - ...                                                │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ 🦞 list files in workspace...              [Ctrl+C: quit]       │
└─────────────────────────────────────────────────────────────────┘
```

## Features

### 1. Layout Components
- **Header Bar**: Logo, version, current model, provider status
- **Chat Area**: Scrollable conversation history with role indicators
- **Input Area**: Multi-line input with syntax highlighting
- **Status Bar**: Tool execution status, key bindings hint
- **Tool Panel**: Optional side panel showing available tools

### 2. Key Bindings
| Key | Action |
|-----|--------|
| `Enter` | Send message |
| `Shift+Enter` | New line in input |
| `↑/↓` | Scroll history |
| `Ctrl+L` | Clear screen |
| `Ctrl+T` | Toggle tool panel |
| `Ctrl+C` | Quit |
| `Tab` | Auto-complete commands |

### 3. Visual Features
- **Role Colors**: User (cyan), Assistant (green), System (gray), Tool (yellow)
- **Tool Visualization**: Expandable tool execution blocks
- **Typing Indicator**: When LLM is generating
- **Scrollback**: Keep last N messages in memory
- **Word Wrap**: Proper handling of long lines

## Implementation

### New Dependencies
```nim
# nimclaw.nimble
requires "illwill >= 0.4.0"
```

### Module Structure
```
src/nimclaw/
├── tui/
│   └── core.nim          # TUI implementation using illwill
├── nimclaw.nim           # Add --tui flag
└── ...
```

### Usage
```bash
# New TUI mode (default)
nimclaw agent --tui

# Classic CLI mode
nimclaw agent --cli

# One-shot mode (unchanged)
nimclaw agent --message "hello"
```

### Example Implementation (core.nim)

```nim
import illwill
import ../agent/loop
import chronos

type
  ChatMessage = object
    role: string
    content: string

  TuiApp = ref object
    tb: TerminalBuffer
    running: bool
    agentLoop: AgentLoop
    messages: seq[ChatMessage]
    inputBuffer: string
    scrollOffset: int

proc newTuiApp(agentLoop: AgentLoop): TuiApp =
  illwillInit(fullscreen=true)
  hideCursor()
  result = TuiApp(
    tb: newTerminalBuffer(terminalWidth(), terminalHeight()),
    running: true,
    agentLoop: agentLoop,
    messages: @[],
    inputBuffer: "",
    scrollOffset: 0
  )

proc render(app: TuiApp) =
  app.tb.clear()
  
  # Header
  app.tb.setBackgroundColor(bgBlue, true)
  app.tb.write(0, 0, "🦞 PicoClaw")
  app.tb.resetAttributes()
  
  # Chat area
  let chatHeight = terminalHeight() - 4
  for i, msg in app.messages:
    let y = 2 + i - app.scrollOffset
    if y >= 2 and y < chatHeight:
      case msg.role:
      of "user": app.tb.setForegroundColor(fgCyan)
      of "assistant": app.tb.setForegroundColor(fgGreen)
      else: discard
      app.tb.write(2, y, msg.content)
      app.tb.resetAttributes()
  
  # Input area
  app.tb.drawRect(0, chatHeight, terminalWidth()-1, terminalHeight()-1)
  app.tb.write(2, chatHeight+1, "🦞 " & app.inputBuffer)
  
  app.tb.display()

proc run(app: TuiApp) {.async.} =
  while app.running:
    let key = getKey()
    case key
    of Key.Escape: app.running = false
    of Key.Enter:
      let response = await app.agentLoop.processDirect(app.inputBuffer, "tui")
      app.messages.add(ChatMessage(role: "user", content: app.inputBuffer))
      app.messages.add(ChatMessage(role: "assistant", content: response))
      app.inputBuffer = ""
    of Key.Char:
      if key.char.isSome:
        app.inputBuffer.add(key.char.get())
    else: discard
    
    app.render()
    await sleepAsync(20)
  
  illwillDeinit()
```

## Migration Path
1. Keep existing `agent()` proc for CLI mode
2. Add new `agentTui()` proc for TUI mode  
3. Default to TUI in interactive mode, add `--cli` flag for classic mode

## Notes
- illwill uses immediate mode UI (similar to Dear ImGui)
- Double buffering ensures smooth rendering
- Non-blocking input allows async agent operations
- Terminal is restored on exit

## Files Created
- `src/nimclaw/tui/core.nim` - TUI implementation (requires illwill)
- `TUI_PLAN.md` - This plan document

## Next Steps
1. Install illwill: `nimble install illwill`
2. Uncomment the import in `src/nimclaw.nim`
3. Uncomment the TUI code in `agent()` proc
4. Test and iterate on the UI
