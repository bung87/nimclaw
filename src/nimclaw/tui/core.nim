import std/[strutils]
import illwill
import chronos
import ../providers/types as providers_types
import ../agent/loop

type
  ChatMessage* = object
    role*: string
    content*: string
    toolCalls*: seq[providers_types.ToolCall]

  TuiApp* = ref object
    tb*: TerminalBuffer
    running*: bool
    agentLoop*: AgentLoop
    messages*: seq[ChatMessage]
    inputBuffer*: string
    visualInput*: string # What portion of input is visible
    cursorX*: int        # Logical cursor position in inputBuffer
    visualCursorX*: int  # Cursor position in visualInput
    needsRedraw*: bool
    isGenerating*: bool

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6     # After "🦞 " prompt
  InputMaxWidth* = 50 # Max visible input width

proc newTuiApp*(agentLoop: AgentLoop): TuiApp =
  illwillInit(fullscreen = true)
  hideCursor()

  result = TuiApp(
    tb: newTerminalBuffer(terminalWidth(), terminalHeight()),
    running: true,
    agentLoop: agentLoop,
    messages: @[],
    inputBuffer: "",
    visualInput: "",
    cursorX: 0,
    visualCursorX: 0,
    needsRedraw: true,
    isGenerating: false
  )

proc chatHeight(app: TuiApp): int =
  terminalHeight() - HeaderHeight - InputHeight - 1

# Calculate what portion of input to show (left-to-right)
proc updateVisualInput(app: TuiApp) =
  let w = terminalWidth()
  let maxWidth = w - InputStartX - 2 # Leave some margin

  if app.inputBuffer.len <= maxWidth:
    # Fits entirely
    app.visualInput = app.inputBuffer
    app.visualCursorX = app.cursorX
  else:
    # Need to scroll
    var startPos = 0
    var endPos = maxWidth

    if app.cursorX > maxWidth div 2:
      # Cursor is past halfway, scroll to center it
      startPos = min(app.cursorX - maxWidth div 2, app.inputBuffer.len - maxWidth)
      endPos = startPos + maxWidth

    app.visualInput = app.inputBuffer.substr(startPos, endPos - 1)
    app.visualCursorX = app.cursorX - startPos

proc addMessage(app: TuiApp, role, content: string, toolCalls: seq[providers_types.ToolCall] = @[]) =
  app.messages.add(ChatMessage(role: role, content: content, toolCalls: toolCalls))
  app.needsRedraw = true

proc sendMessage(app: TuiApp) {.async.} =
  let userInput = app.inputBuffer.strip()
  if userInput.len == 0: return

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

  of Key.Escape, Key.CtrlC:
    app.running = false

  of Key.Enter:
    if app.inputBuffer.len > 0:
      discard app.sendMessage()

  of Key.Backspace:
    if app.cursorX > 0 and app.inputBuffer.len > 0:
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

  # Draw header background first
  for x in 0..<w:
    app.tb.write(x, 0, " ", bgBlue)

  # Reset attributes before writing text (emoji doesn't need bgBlue, bg already set)
  app.tb.resetAttributes()

  # Title - write without bgBlue since background is already blue
  app.tb.write(2, 0, "🦞 PicoClaw")

  # Status info (right aligned)
  let statusText = "Interactive Mode  |  Ctrl+C: Quit"
  let statusX = w - statusText.len - 2
  if statusX > 20:
    app.tb.write(statusX, 0, statusText)

  # Reset attributes before separator
  app.tb.resetAttributes()

  # Separator line
  for x in 0..<w:
    app.tb.write(x, 1, "─")

proc renderChat(app: TuiApp) =
  let w = terminalWidth()
  let h = app.chatHeight()
  let startY = HeaderHeight + 1

  # Clear chat area (reset attributes first to prevent color bleeding)
  app.tb.resetAttributes()
  for y in startY..<(startY + h):
    for x in 0..<w:
      app.tb.write(x, y, " ")

  # Draw messages from bottom up
  var currentY = startY + h - 1

  for i in countdown(app.messages.len - 1, 0):
    if currentY < startY: break

    let msg = app.messages[i]
    let lines = msg.content.splitLines()

    # Draw from last line to first
    for lineIdx in countdown(lines.len - 1, 0):
      if currentY < startY: break

      let line = lines[lineIdx]

      # Role indicator on first line of message
      if lineIdx == 0:
        case msg.role:
        of "user":
          app.tb.write(2, currentY, "You:", fgCyan)
        of "assistant":
          app.tb.write(2, currentY, "🦞:", fgGreen)
        of "system":
          app.tb.write(2, currentY, "⚙:", fgYellow)
        else:
          app.tb.write(2, currentY, "•")

        # Reset attributes before content
        app.tb.resetAttributes()

        # Content (truncated to fit)
        let maxWidth = w - 10
        let displayText = if line.len > maxWidth: line[0..<maxWidth] & "..." else: line
        app.tb.write(8, currentY, displayText)
      else:
        # Continuation lines
        let maxWidth = w - 10
        let displayText = if line.len > maxWidth: line[0..<maxWidth] & "..." else: line
        app.tb.write(8, currentY, displayText)

      currentY.dec

proc renderInput(app: TuiApp) =
  let w = terminalWidth()
  let h = terminalHeight()
  let inputY = h - 2

  app.tb.resetAttributes()

  # Separator line
  for x in 0..<w:
    app.tb.write(x, h - 3, "─")

  # Input prompt
  app.tb.write(2, inputY, "🦞", fgCyan)
  app.tb.resetAttributes()

  # Visible input text
  app.tb.write(InputStartX, inputY, app.visualInput)

  # Show cursor (blinking underscore style like tui_widget)
  let cursorScreenX = InputStartX + app.visualCursorX
  if app.cursorX < app.inputBuffer.len:
    # Cursor on a character - show character with inverse/blink
    app.tb.write(cursorScreenX, inputY, $app.visualInput[app.visualCursorX], styleUnderscore)
  else:
    # Cursor at end - show underscore
    app.tb.write(cursorScreenX, inputY, "_", styleUnderscore)

  app.tb.resetAttributes()

  # Generating indicator
  if app.isGenerating:
    app.tb.write(w - 15, inputY, "[thinking...]", fgYellow)

proc render*(app: TuiApp) =
  if not app.needsRedraw: return

  app.tb.clear()
  app.renderHeader()
  app.renderChat()
  app.renderInput()
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
    await sleepAsync(20)

  illwillDeinit()
  showCursor()

proc cleanup*() {.noconv.} =
  illwillDeinit()
  showCursor()
