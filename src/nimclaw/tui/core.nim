import std/[strutils, unicode]
import std/terminal except showCursor, hideCursor
import textalot
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
    ctrlDCount*: int
    ctrlDHintVisible*: bool

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6

proc readEventGcsafe(): Event =
  {.gcsafe.}:
    result = readEvent()

proc deinitTextalotGcsafe() =
  {.gcsafe.}:
    deinitTextalot()

proc newTuiApp*(agentLoop: AgentLoop, cfg: Config): TuiApp =
  initTextalot()
  # Disable mouse tracking so standard terminal text selection works
  stdout.write("\x1b[?1003l\x1b[?1006l")
  stdout.flushFile()

  result = TuiApp(
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
    ctrlDCount: 0,
    ctrlDHintVisible: false
  )

proc chatHeight(app: TuiApp): int =
  getTerminalHeight() - HeaderHeight - InputHeight - 1

proc chatWidth(app: TuiApp): int =
  getTerminalWidth()

# Calculate visible portion of input
proc updateVisualInput(app: TuiApp) =
  let maxWidth = getTerminalWidth() - InputStartX - 4
  let totalRunes = app.inputBuffer.runeLen
  let cursorRunes = app.inputBuffer[0..<app.cursorX].runeLen

  if totalRunes <= maxWidth:
    app.visualInput = app.inputBuffer
    app.visualCursorX = cursorRunes
  else:
    var startRunePos = 0
    if cursorRunes > maxWidth div 2:
      startRunePos = min(cursorRunes - maxWidth div 2, totalRunes - maxWidth)
    let endRunePos = min(startRunePos + maxWidth - 1, totalRunes - 1)

    var res = ""
    var currentRune = 0
    for r in app.inputBuffer.runes:
      if currentRune >= startRunePos and currentRune <= endRunePos:
        res.add(r.toUTF8)
      if currentRune > endRunePos:
        break
      currentRune.inc

    app.visualInput = res
    app.visualCursorX = cursorRunes - startRunePos

proc runeDisplayWidth(r: Rune): int =
  ## Approximate terminal display width for a rune.
  ## Heuristic: CJK and emoji (outside BMP) are width 2.
  let code = r.ord
  if code <= 0x1F: return 0
  if code >= 0x1100 and code <= 0x115F: return 2
  if code >= 0x2E80 and code <= 0xA4CF: return 2
  if code >= 0xAC00 and code <= 0xD7A3: return 2
  if code >= 0xF900 and code <= 0xFAFF: return 2
  if code >= 0xFE30 and code <= 0xFE6F: return 2
  if code >= 0xFF00 and code <= 0xFF60: return 2
  if code >= 0xFFE0 and code <= 0xFFE6: return 2
  if code >= 0x20000 and code <= 0x2FFFF: return 2
  if code >= 0x30000 and code <= 0x3FFFF: return 2
  if code > 0xFFFF: return 2
  return 1

proc stringDisplayWidth(s: string): int =
  result = 0
  for r in s.runes:
    result += runeDisplayWidth(r)

proc drawTextWide*(text: string, x, y: int, fg, bg: uint32, style: uint16 = STYLE_NONE) =
  ## Draw text accounting for wide characters (emojis, CJK).
  let w = getTerminalWidth()
  var currentX = x
  if y < 0 or y >= getTerminalHeight():
    return
  for r in text.runes:
    let rw = runeDisplayWidth(r)
    if currentX >= 0 and currentX < w:
      drawText(r.toUTF8(), currentX, y, fg, bg, style)
    currentX += rw

proc wrapText(text: string, maxWidth: int): seq[string] =
  ## Word wrap with fallback for no-space languages (e.g. CJK)
  result = @[]

  for rawLine in text.splitLines():
    var currentLine = ""
    var currentWidth = 0
    var lineResult: seq[string] = @[]

    for word in rawLine.split(' '):
      let wordWidth = stringDisplayWidth(word)
      if word.len == 0:
        continue
      if currentLine.len == 0:
        currentLine = word
        currentWidth = wordWidth
      elif currentWidth + 1 + wordWidth <= maxWidth:
        currentLine.add(" " & word)
        currentWidth += 1 + wordWidth
      else:
        lineResult.add(currentLine)
        currentLine = word
        currentWidth = wordWidth

    if currentLine.len > 0:
      lineResult.add(currentLine)
    elif rawLine.len == 0:
      lineResult.add("")

    # Handle lines that are still too long
    for line in lineResult:
      if stringDisplayWidth(line) <= maxWidth:
        result.add(line)
      else:
        var current = ""
        var currentWidth = 0
        for r in line.runes:
          let rw = runeDisplayWidth(r)
          if currentWidth + rw > maxWidth:
            result.add(current)
            current = r.toUTF8
            currentWidth = rw
          else:
            current.add(r.toUTF8)
            currentWidth += rw
        if current.len > 0:
          result.add(current)

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

  # Add placeholder message for assistant that will be updated incrementally
  let assistantMsgIdx = app.messages.len
  app.addMessage("assistant", "")

  # Create callback for incremental updates
  let onUpdate = proc(content: string, reasoning: string, isDone: bool) {.gcsafe.} =
    {.gcsafe.}:
      if assistantMsgIdx < app.messages.len:
        app.messages[assistantMsgIdx].content = content
        app.needsRedraw = true

  let response = await app.agentLoop.processDirect(userInput, "tui:default", onUpdate)

  # Ensure final content is set
  if assistantMsgIdx < app.messages.len:
    app.messages[assistantMsgIdx].content = response
  app.isGenerating = false
  app.needsRedraw = true

proc deleteRuneBefore(app: TuiApp) =
  var newBuffer = ""
  var currentPos = 0
  for r in app.inputBuffer.runes:
    let rstr = r.toUTF8
    if currentPos + rstr.len == app.cursorX:
      app.cursorX = currentPos
    else:
      newBuffer.add(rstr)
    currentPos += rstr.len
  app.inputBuffer = newBuffer

proc deleteRuneAt(app: TuiApp) =
  var newBuffer = ""
  var currentPos = 0
  for r in app.inputBuffer.runes:
    let rstr = r.toUTF8
    if currentPos != app.cursorX:
      newBuffer.add(rstr)
    currentPos += rstr.len
  app.inputBuffer = newBuffer

proc moveCursorLeft(app: TuiApp) =
  if app.cursorX > 0:
    var prevPos = 0
    for r in app.inputBuffer.runes:
      let rstr = r.toUTF8
      if prevPos + rstr.len == app.cursorX:
        app.cursorX = prevPos
        return
      prevPos += rstr.len

proc moveCursorRight(app: TuiApp) =
  if app.cursorX < app.inputBuffer.len:
    var currentPos = 0
    for r in app.inputBuffer.runes:
      let rstr = r.toUTF8
      if currentPos == app.cursorX:
        app.cursorX = currentPos + rstr.len
        return
      currentPos += rstr.len

proc countNewlines(s: string, upToRunePos: int): int =
  var count = 0
  var runePos = 0
  for r in s.runes:
    if runePos >= upToRunePos: break
    if r == Rune('\n'): count.inc
    runePos.inc
  result = count

proc lastNewlineRunePos(s: string, upToRunePos: int): int =
  var last = -1
  var runePos = 0
  for r in s.runes:
    if runePos >= upToRunePos: break
    if r == Rune('\n'): last = runePos
    runePos.inc
  result = last

proc handleEvent(app: TuiApp, ev: Event) =
  if ev of KeyEvent:
    let kev = cast[KeyEvent](ev)
    let key = kev.key

    if key != EVENT_KEY_CTRL_D:
      app.ctrlDCount = 0
      if app.ctrlDHintVisible:
        app.ctrlDHintVisible = false
        app.needsRedraw = true

    case key
    of EVENT_KEY_ESC:
      app.running = false

    of EVENT_KEY_CTRL_C:
      app.running = false

    of EVENT_KEY_ENTER:
      if app.inputBuffer.len > 0:
        discard app.sendMessage()

    of EVENT_KEY_SPACE:
      app.inputBuffer.insert(" ", app.cursorX)
      app.cursorX.inc
      app.updateVisualInput()
      app.needsRedraw = true

    of EVENT_KEY_BACKSPACE, EVENT_KEY_BACKSPACE2:
      if app.cursorX > 0:
        app.deleteRuneBefore()
        app.updateVisualInput()
        app.needsRedraw = true

    of EVENT_KEY_DELETE:
      if app.cursorX < app.inputBuffer.len:
        app.deleteRuneAt()
        app.updateVisualInput()
        app.needsRedraw = true

    of EVENT_KEY_ARROW_LEFT:
      app.moveCursorLeft()
      app.updateVisualInput()
      app.needsRedraw = true

    of EVENT_KEY_ARROW_RIGHT:
      app.moveCursorRight()
      app.updateVisualInput()
      app.needsRedraw = true

    of EVENT_KEY_HOME:
      app.cursorX = 0
      app.updateVisualInput()
      app.needsRedraw = true

    of EVENT_KEY_END:
      app.cursorX = app.inputBuffer.len
      app.updateVisualInput()
      app.needsRedraw = true

    of EVENT_KEY_ARROW_UP:
      if app.scrollOffset > 0:
        app.scrollOffset.dec
        app.needsRedraw = true

    of EVENT_KEY_ARROW_DOWN:
      let maxScroll = max(0, app.messages.len - app.chatHeight())
      if app.scrollOffset < maxScroll:
        app.scrollOffset.inc
        app.needsRedraw = true

    of EVENT_KEY_PGUP:
      app.scrollOffset = max(0, app.scrollOffset - app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_PGDN:
      let maxScroll = max(0, app.messages.len - app.chatHeight())
      app.scrollOffset = min(maxScroll, app.scrollOffset + app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_CTRL_L:
      # Clear screen
      app.messages = @[]
      app.scrollOffset = 0
      app.needsRedraw = true

    of EVENT_KEY_CTRL_D:
      app.ctrlDCount.inc
      if app.ctrlDCount >= 2:
        app.running = false
      elif app.ctrlDCount == 1 and not app.ctrlDHintVisible:
        app.ctrlDHintVisible = true
        app.needsRedraw = true

    of EVENT_KEY_CTRL_T:
      # Toggle tool panel (placeholder)
      discard

    else:
      # Handle printable characters (ASCII + Unicode)
      if key >= 0x20 and key <= 0x10FFFF'u32:
        let c = Rune(key.int).toUTF8()
        app.inputBuffer.insert(c, app.cursorX)
        app.cursorX += c.len
        app.updateVisualInput()
        app.needsRedraw = true

  elif ev of MouseEvent:
    let mev = cast[MouseEvent](ev)
    case mev.key
    of EVENT_MOUSE_WHEEL_UP:
      if app.scrollOffset > 0:
        app.scrollOffset.dec
      app.needsRedraw = true
    of EVENT_MOUSE_WHEEL_DOWN:
      let maxScroll = max(0, app.messages.len - app.chatHeight())
      if app.scrollOffset < maxScroll:
        app.scrollOffset.inc
      app.needsRedraw = true
    else:
      discard

  elif ev of ResizeEvent:
    {.gcsafe.}:
      recreateBuffers()
    app.needsRedraw = true

proc renderHeader(app: TuiApp) =
  let w = getTerminalWidth()
  let provider = app.cfg.agents.defaults.provider
  let model = app.cfg.agents.defaults.model

  # Title with color
  drawTextWide("🦞 ", 2, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_BOLD)
  drawTextWide("Nimclaw", 5, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_BOLD)

  # Provider and model info (center-right)
  let infoText = provider & " / " & model
  let infoX = w - stringDisplayWidth(infoText) - 15
  if infoX > 20:
    drawTextWide(infoText, infoX, 0, FG_COLOR_CYAN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Status (rightmost)
  if app.isGenerating:
    drawTextWide("●", w - 3, 0, FG_COLOR_YELLOW, BG_COLOR_DEFAULT, STYLE_NONE)
  else:
    drawTextWide("○", w - 3, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Separator line (dim)
  drawRectangle(0, 1, w, 2, BG_COLOR_DEFAULT, FG_COLOR_DEFAULT, "─", STYLE_FAINT)

proc renderChat(app: TuiApp) =
  let w = app.chatWidth()
  let h = app.chatHeight()
  let startY = HeaderHeight + 1
  let maxContentWidth = w - 12

  # Clear chat area
  removeArea(0, startY, w, startY + h)

  # Build display lines from messages
  var displayLines: seq[tuple[role: string, text: string, indent: int]] = @[]

  for msg in app.messages:
    # Role indicator line
    case msg.role:
    of "user":
      displayLines.add(("user", "You:", 0))
    of "assistant":
      displayLines.add(("assistant", ">", 0))
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

  # Draw Ctrl+D hint at the bottom of chat area if visible
  if app.ctrlDHintVisible and currentY >= startY:
    let hint = "⚠ Press Ctrl+D again to exit"
    drawTextWide(hint, 2, currentY, FG_COLOR_YELLOW, BG_COLOR_DEFAULT, STYLE_FAINT)
    currentY.dec

  let startIdx = max(0, displayLines.len - h - app.scrollOffset)
  let endIdx = min(displayLines.len - 1, displayLines.len - 1 - app.scrollOffset)

  for i in countdown(endIdx, startIdx):
    if currentY < startY: break

    let (role, text, indent) = displayLines[i]

    if text.len > 0:
      # Set color based on role
      var fg = FG_COLOR_DEFAULT
      case role:
      of "user": fg = FG_COLOR_CYAN
      of "assistant": fg = FG_COLOR_GREEN
      of "system": fg = FG_COLOR_YELLOW
      of "tool": fg = FG_COLOR_MAGENTA
      drawTextWide(text, indent, currentY, fg, BG_COLOR_DEFAULT, STYLE_NONE)

    currentY.dec

proc renderInput(app: TuiApp) =
  let w = getTerminalWidth()
  let h = getTerminalHeight()
  let inputY = h - 2

  # Separator line (dim)
  drawRectangle(0, h - 3, w, h - 2, BG_COLOR_DEFAULT, FG_COLOR_DEFAULT, "─", STYLE_FAINT)

  # Input prompt
  drawTextWide("🦞", 2, inputY, FG_COLOR_CYAN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Visible input text
  let inputLines = app.visualInput.splitLines()
  for i, line in inputLines:
    let y = inputY + i
    if y < h - 1:
      drawTextWide(line, InputStartX, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE)

proc positionCursor(app: TuiApp) =
  let w = getTerminalWidth()
  let h = getTerminalHeight()
  let inputY = h - 2

  let cursorY = inputY + countNewlines(app.visualInput, app.visualCursorX)
  let lineStartRunePos = lastNewlineRunePos(app.visualInput, app.visualCursorX) + 1
  let cursorXInLine = app.visualCursorX - lineStartRunePos
  let cursorScreenX = InputStartX + cursorXInLine

  if cursorScreenX < w - 1 and cursorY < h - 1:
    terminal.setCursorPos(cursorScreenX, cursorY)
    showCursor()

proc render*(app: TuiApp) =
  if not app.needsRedraw: return

  let w = getTerminalWidth()
  let h = getTerminalHeight()
  {.gcsafe.}:
    removeArea(0, 0, w, h)
    app.renderHeader()
    app.renderChat()
    app.renderInput()
    texalotRender()
    app.positionCursor()

  app.needsRedraw = false

proc run*(app: TuiApp) {.async.} =
  app.updateVisualInput()
  app.render()

  while app.running:
    let ev = readEventGcsafe()
    app.handleEvent(ev)

    if app.needsRedraw:
      app.render()

    await sleepAsync(20 * Millisecond)

  deinitTextalotGcsafe()

proc cleanup*() {.noconv.} =
  deinitTextalot()
