import std/[strutils, terminal]
import illwill
import chronos
import ../providers/types as providers_types
import ../agent/loop
import ../config

type
  ChatMessage* = object
    role*: string
    content*: string
    toolCalls*: seq[providers_types.ToolCall]
    expanded*: bool # For tool call visualization

  TuiApp* = ref object
    tb*: TerminalBuffer
    running*: bool
    agentLoop*: AgentLoop
    cfg*: Config
    messages*: seq[ChatMessage]
    inputBuffer*: string
    visualInput*: string
    cursorX*: int
    visualCursorX*: int
    scrollOffset*: int
    needsRedraw*: bool
    isGenerating*: bool
    showHelp*: bool
    helpScroll*: int

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6
  HelpWidth = 30

proc newTuiApp*(agentLoop: AgentLoop, cfg: Config): TuiApp =
  illwillInit(fullscreen = true)
  hideCursor()
  setDoubleBuffering(false)

  result = TuiApp(
    tb: newTerminalBuffer(terminalWidth(), terminalHeight()),
    running: true,
    agentLoop: agentLoop,
    cfg: cfg,
    messages: @[],
    inputBuffer: "",
    visualInput: "",
    cursorX: 0,
    visualCursorX: 0,
    scrollOffset: 0,
    needsRedraw: true,
    isGenerating: false,
    showHelp: false,
    helpScroll: 0
  )

proc chatHeight(app: TuiApp): int =
  terminalHeight() - HeaderHeight - InputHeight - 1

proc chatWidth(app: TuiApp): int =
  let w = terminalWidth()
  if app.showHelp:
    w - HelpWidth - 1
  else:
    w

# Calculate visible portion of input
proc updateVisualInput(app: TuiApp) =
  let maxWidth = terminalWidth() - InputStartX - 4

  if app.inputBuffer.len <= maxWidth:
    app.visualInput = app.inputBuffer
    app.visualCursorX = app.cursorX
  else:
    var startPos = 0
    if app.cursorX > maxWidth div 2:
      startPos = min(app.cursorX - maxWidth div 2, app.inputBuffer.len - maxWidth)
    app.visualInput = app.inputBuffer.substr(startPos, startPos + maxWidth - 1)
    app.visualCursorX = app.cursorX - startPos

proc wrapText(text: string, maxWidth: int): seq[string] =
  ## Simple word wrap
  result = @[]
  var currentLine = ""

  for word in text.split(' '):
    if currentLine.len == 0:
      currentLine = word
    elif currentLine.len + 1 + word.len <= maxWidth:
      currentLine.add(" " & word)
    else:
      result.add(currentLine)
      currentLine = word

  if currentLine.len > 0:
    result.add(currentLine)

  # Handle empty result
  if result.len == 0:
    result.add("")

proc addMessage(app: TuiApp, role, content: string, toolCalls: seq[providers_types.ToolCall] = @[]) =
  app.messages.add(ChatMessage(
    role: role,
    content: content,
    toolCalls: toolCalls,
    expanded: false
  ))
  app.needsRedraw = true

proc sendMessage(app: TuiApp) {.async.} =
  let userInput = app.inputBuffer.strip()
  if userInput.len == 0: return

  # Handle quit command
  if userInput.toLowerAscii() in ["quit", "exit", "q"]:
    app.running = false
    return

  app.addMessage("user", userInput)
  app.inputBuffer = ""
  app.cursorX = 0
  app.updateVisualInput()
  app.isGenerating = true
  app.needsRedraw = true

  let response = await app.agentLoop.processDirect(userInput, "tui:default")

  app.addMessage("assistant", response)
  app.isGenerating = false
  app.needsRedraw = true

proc handleInput(app: TuiApp, key: Key) =
  case key
  of Key.None: discard

  of Key.Escape:
    if app.showHelp:
      app.showHelp = false
      app.needsRedraw = true
    else:
      app.running = false

  of Key.CtrlC:
    app.running = false

  of Key.Enter:
    if app.inputBuffer.len > 0:
      discard app.sendMessage()

  of Key.Backspace:
    if app.cursorX > 0:
      app.inputBuffer.delete(app.cursorX - 1 .. app.cursorX - 1)
      app.cursorX.dec
      app.updateVisualInput()
      app.needsRedraw = true

  of Key.Delete:
    if app.cursorX < app.inputBuffer.len:
      app.inputBuffer.delete(app.cursorX .. app.cursorX)
      app.updateVisualInput()
      app.needsRedraw = true

  of Key.Left:
    if app.cursorX > 0:
      app.cursorX.dec
      app.updateVisualInput()
      app.needsRedraw = true

  of Key.Right:
    if app.cursorX < app.inputBuffer.len:
      app.cursorX.inc
      app.updateVisualInput()
      app.needsRedraw = true

  of Key.Home:
    app.cursorX = 0
    app.updateVisualInput()
    app.needsRedraw = true

  of Key.End:
    app.cursorX = app.inputBuffer.len
    app.updateVisualInput()
    app.needsRedraw = true

  of Key.Up:
    if app.showHelp:
      if app.helpScroll > 0:
        app.helpScroll.dec
        app.needsRedraw = true
    else:
      if app.scrollOffset > 0:
        app.scrollOffset.dec
        app.needsRedraw = true

  of Key.Down:
    if app.showHelp:
      app.helpScroll.inc
      app.needsRedraw = true
    else:
      let maxScroll = max(0, app.messages.len - app.chatHeight())
      if app.scrollOffset < maxScroll:
        app.scrollOffset.inc
        app.needsRedraw = true

  of Key.PageUp:
    if app.showHelp:
      app.helpScroll = max(0, app.helpScroll - 5)
    else:
      app.scrollOffset = max(0, app.scrollOffset - app.chatHeight())
    app.needsRedraw = true

  of Key.PageDown:
    if app.showHelp:
      app.helpScroll.inc(5)
    else:
      let maxScroll = max(0, app.messages.len - app.chatHeight())
      app.scrollOffset = min(maxScroll, app.scrollOffset + app.chatHeight())
    app.needsRedraw = true

  of Key.CtrlL:
    # Clear screen
    app.messages = @[]
    app.scrollOffset = 0
    app.needsRedraw = true

  of Key.CtrlH:
    # Toggle help
    app.showHelp = not app.showHelp
    app.needsRedraw = true

  of Key.CtrlT:
    # Toggle tool panel (placeholder)
    discard

  else:
    # Handle printable characters
    let keyOrd = ord(key)
    if keyOrd >= 32 and keyOrd <= 126:
      let c = chr(keyOrd)
      app.inputBuffer.insert($c, app.cursorX)
      app.cursorX.inc
      app.updateVisualInput()
      app.needsRedraw = true

proc renderHeader(app: TuiApp) =
  let w = terminalWidth()
  let provider = app.cfg.agents.defaults.provider
  let model = app.cfg.agents.defaults.model

  # Title with color
  app.tb.write(2, 0, "🦞 ", fgGreen)
  app.tb.write(5, 0, "Nimclaw", fgGreen, {styleBright})

  # Provider and model info (center-right)
  let infoText = provider & " / " & model
  let infoX = w - infoText.len - 15
  if infoX > 20:
    app.tb.write(infoX, 0, infoText, fgCyan)

  # Status (rightmost)
  if app.isGenerating:
    app.tb.write(w - 3, 0, "●", fgYellow)
  else:
    app.tb.write(w - 3, 0, "○", fgGreen)

  # Separator line (dim)
  app.tb.resetAttributes()
  for x in 0..<w:
    app.tb.write(x, 1, "─", {styleDim})

proc renderHelpPanel(app: TuiApp) =
  if not app.showHelp: return

  let w = terminalWidth()
  let h = terminalHeight()
  let panelX = w - HelpWidth

  # Draw panel border
  for y in 2..<h-3:
    app.tb.write(panelX, y, "│", {styleDim})

  # Help content
  let helpItems = @[
    ("Keybindings", ""),
    ("", ""),
    ("Enter", "Send message"),
    ("Shift+Enter", "New line"),
    ("↑/↓", "Scroll chat"),
    ("PgUp/PgDn", "Page scroll"),
    ("Ctrl+H", "Toggle help"),
    ("Ctrl+L", "Clear chat"),
    ("Ctrl+C", "Quit"),
    ("", ""),
    ("Provider", app.cfg.agents.defaults.provider),
    ("Model", app.cfg.agents.defaults.model),
  ]

  var y = 3
  for i, (key, desc) in helpItems:
    if y >= h - 4: break
    if i < app.helpScroll: continue

    if key.len > 0 and desc.len > 0:
      app.tb.write(panelX + 2, y, key, fgYellow)
      app.tb.write(panelX + 14, y, desc)
    elif key.len > 0:
      app.tb.write(panelX + 2, y, key, {styleBright})
    y.inc

proc renderChat(app: TuiApp) =
  let w = app.chatWidth()
  let h = app.chatHeight()
  let startY = HeaderHeight + 1
  let maxContentWidth = w - 12

  # Clear chat area
  app.tb.resetAttributes()
  for y in startY..<(startY + h):
    for x in 0..<w:
      app.tb.write(x, y, " ")

  # Build display lines from messages
  var displayLines: seq[tuple[role: string, text: string, indent: int]] = @[]

  for msg in app.messages:
    # Role indicator line
    case msg.role:
    of "user":
      displayLines.add(("user", "You:", 0))
    of "assistant":
      displayLines.add(("assistant", "🦞:", 0))
    of "system":
      displayLines.add(("system", "⚙:", 0))
    of "tool":
      displayLines.add(("tool", "🔧:", 0))
    else:
      displayLines.add(("", "•", 0))

    # Content lines (wrapped)
    let wrapped = wrapText(msg.content, maxContentWidth)
    for i, line in wrapped:
      displayLines.add((msg.role, line, 6))

    # Empty line between messages
    displayLines.add(("", "", 0))

  # Draw from bottom up with scroll offset
  var currentY = startY + h - 1
  let startIdx = max(0, displayLines.len - h - app.scrollOffset)
  let endIdx = min(displayLines.len - 1, displayLines.len - 1 - app.scrollOffset)

  for i in countdown(endIdx, startIdx):
    if currentY < startY: break

    let (role, text, indent) = displayLines[i]

    if text.len > 0:
      # Set color based on role
      case role:
      of "user":
        app.tb.write(2, currentY, text, fgCyan)
      of "assistant":
        app.tb.write(2, currentY, text, fgGreen)
      of "system":
        app.tb.write(2, currentY, text, fgYellow)
      of "tool":
        app.tb.write(2, currentY, text, fgMagenta)
      else:
        app.tb.write(indent, currentY, text)

      app.tb.resetAttributes()

    currentY.dec

proc renderInput(app: TuiApp) =
  let w = terminalWidth()
  let h = terminalHeight()
  let inputY = h - 2

  app.tb.resetAttributes()

  # Separator line (dim)
  for x in 0..<w:
    app.tb.write(x, h - 3, "─", {styleDim})

  # Input prompt
  app.tb.write(2, inputY, "🦞", fgCyan)
  app.tb.resetAttributes()

  # Visible input text
  let inputLines = app.visualInput.splitLines()
  for i, line in inputLines:
    let y = inputY + i
    if y < h - 1:
      app.tb.write(InputStartX, y, line)

  # Cursor (underscore style)
  let cursorY = inputY + app.visualInput[0..<app.visualCursorX].count('\n')
  let lineStart = app.visualInput.rfind('\n', 0, app.visualCursorX - 1) + 1
  let cursorXInLine = app.visualCursorX - lineStart
  let cursorScreenX = InputStartX + cursorXInLine

  if cursorScreenX < w - 1 and cursorY < h - 1:
    if app.cursorX < app.inputBuffer.len and app.inputBuffer[app.cursorX] != '\n':
      app.tb.write(cursorScreenX, cursorY, $app.inputBuffer[app.cursorX], styleUnderscore)
    else:
      app.tb.write(cursorScreenX, cursorY, "_", styleUnderscore)

  app.tb.resetAttributes()

proc render*(app: TuiApp) =
  if not app.needsRedraw: return

  app.tb.clear()
  app.renderHeader()
  app.renderChat()
  app.renderInput()
  app.renderHelpPanel()
  app.tb.display()

  app.needsRedraw = false

proc run*(app: TuiApp) {.async.} =
  app.updateVisualInput()
  app.render()

  while app.running:
    let key = getKey()
    if key != Key.None:
      app.handleInput(key)

    app.render()
    await sleepAsync(20 * Millisecond)

  illwillDeinit()
  showCursor()

proc cleanup*() {.noconv.} =
  illwillDeinit()
  showCursor()
