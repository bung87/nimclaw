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
    showHelp*: bool
    helpScroll*: int

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6
  HelpWidth = 30

proc readEventGcsafe(): Event =
  {.gcsafe.}:
    result = readEvent()

proc deinitTextalotGcsafe() =
  {.gcsafe.}:
    deinitTextalot()

proc newTuiApp*(agentLoop: AgentLoop, cfg: Config): TuiApp =
  initTextalot()

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
    showHelp: false,
    helpScroll: 0
  )

proc chatHeight(app: TuiApp): int =
  getTerminalHeight() - HeaderHeight - InputHeight - 1

proc chatWidth(app: TuiApp): int =
  let w = getTerminalWidth()
  if app.showHelp:
    w - HelpWidth - 1
  else:
    w

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

proc wrapText(text: string, maxWidth: int): seq[string] =
  ## Word wrap with fallback for no-space languages (e.g. CJK)
  result = @[]
  var currentLine = ""

  for word in text.split(' '):
    if word.len == 0:
      continue
    if currentLine.len == 0:
      currentLine = word
    elif currentLine.runeLen + 1 + word.runeLen <= maxWidth:
      currentLine.add(" " & word)
    else:
      result.add(currentLine)
      currentLine = word

  if currentLine.len > 0:
    result.add(currentLine)

  # Handle lines that are still too long
  var finalResult: seq[string] = @[]
  for line in result:
    if line.runeLen <= maxWidth:
      finalResult.add(line)
    else:
      var current = ""
      var currentRunes = 0
      for r in line.runes:
        if currentRunes >= maxWidth:
          finalResult.add(current)
          current = r.toUTF8
          currentRunes = 1
        else:
          current.add(r.toUTF8)
          currentRunes.inc
      if current.len > 0:
        finalResult.add(current)

  if finalResult.len == 0:
    finalResult.add("")
  result = finalResult

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

    case key
    of EVENT_KEY_ESC:
      if app.showHelp:
        app.showHelp = false
        app.needsRedraw = true
      else:
        app.running = false

    of EVENT_KEY_CTRL_C:
      app.running = false

    of EVENT_KEY_ENTER:
      if app.inputBuffer.len > 0:
        discard app.sendMessage()

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
      if app.showHelp:
        if app.helpScroll > 0:
          app.helpScroll.dec
          app.needsRedraw = true
      else:
        if app.scrollOffset > 0:
          app.scrollOffset.dec
          app.needsRedraw = true

    of EVENT_KEY_ARROW_DOWN:
      if app.showHelp:
        app.helpScroll.inc
        app.needsRedraw = true
      else:
        let maxScroll = max(0, app.messages.len - app.chatHeight())
        if app.scrollOffset < maxScroll:
          app.scrollOffset.inc
          app.needsRedraw = true

    of EVENT_KEY_PGUP:
      if app.showHelp:
        app.helpScroll = max(0, app.helpScroll - 5)
      else:
        app.scrollOffset = max(0, app.scrollOffset - app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_PGDN:
      if app.showHelp:
        app.helpScroll.inc(5)
      else:
        let maxScroll = max(0, app.messages.len - app.chatHeight())
        app.scrollOffset = min(maxScroll, app.scrollOffset + app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_CTRL_L:
      # Clear screen
      app.messages = @[]
      app.scrollOffset = 0
      app.needsRedraw = true

    of EVENT_KEY_F1:
      # Toggle help
      app.showHelp = not app.showHelp
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
      if app.showHelp:
        if app.helpScroll > 0:
          app.helpScroll.dec
      else:
        if app.scrollOffset > 0:
          app.scrollOffset.dec
      app.needsRedraw = true
    of EVENT_MOUSE_WHEEL_DOWN:
      if app.showHelp:
        app.helpScroll.inc
      else:
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
  drawText("🦞 ", 2, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_BOLD)
  drawText("Nimclaw", 5, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_BOLD)

  # Provider and model info (center-right)
  let infoText = provider & " / " & model
  let infoX = w - infoText.runeLen - 15
  if infoX > 20:
    drawText(infoText, infoX, 0, FG_COLOR_CYAN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Status (rightmost)
  if app.isGenerating:
    drawText("●", w - 3, 0, FG_COLOR_YELLOW, BG_COLOR_DEFAULT, STYLE_NONE)
  else:
    drawText("○", w - 3, 0, FG_COLOR_GREEN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Separator line (dim)
  drawRectangle(0, 1, w, 2, BG_COLOR_DEFAULT, FG_COLOR_DEFAULT, "─", STYLE_FAINT)

proc renderHelpPanel(app: TuiApp) =
  if not app.showHelp: return

  let w = getTerminalWidth()
  let h = getTerminalHeight()
  let panelX = w - HelpWidth

  # Draw panel border
  for y in 2..<h-3:
    drawText("│", panelX, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_FAINT)

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
      drawText(key, panelX + 2, y, FG_COLOR_YELLOW, BG_COLOR_DEFAULT, STYLE_NONE)
      drawText(desc, panelX + 14, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE)
    elif key.len > 0:
      drawText(key, panelX + 2, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_BOLD)
    y.inc

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
      var fg = FG_COLOR_DEFAULT
      case role:
      of "user": fg = FG_COLOR_CYAN
      of "assistant": fg = FG_COLOR_GREEN
      of "system": fg = FG_COLOR_YELLOW
      of "tool": fg = FG_COLOR_MAGENTA
      drawText(text, indent, currentY, fg, BG_COLOR_DEFAULT, STYLE_NONE)

    currentY.dec

proc renderInput(app: TuiApp) =
  let w = getTerminalWidth()
  let h = getTerminalHeight()
  let inputY = h - 2

  # Separator line (dim)
  drawRectangle(0, h - 3, w, h - 2, BG_COLOR_DEFAULT, FG_COLOR_DEFAULT, "─", STYLE_FAINT)

  # Input prompt
  drawText("🦞", 2, inputY, FG_COLOR_CYAN, BG_COLOR_DEFAULT, STYLE_NONE)

  # Visible input text
  let inputLines = app.visualInput.splitLines()
  for i, line in inputLines:
    let y = inputY + i
    if y < h - 1:
      drawText(line, InputStartX, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE)

  # Position real cursor
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
    app.renderHelpPanel()
    texalotRender()

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
