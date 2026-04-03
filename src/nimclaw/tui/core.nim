import std/[strutils, unicode, times, monotimes]
import std/terminal except showCursor, hideCursor
import textalot
import chronos
import ../providers/types as providers_types
import ../agent/loop
import ../config
import markdown_rendering

type
  DisplayLine* = object
    ## A single line ready for display
    text*: string
    fgColor*: uint32
    bgColor*: uint32
    style*: uint16
    indent*: int
    role*: string

  CachedMessage* = object
    ## Cached rendering state for a message
    role*: string
    content*: string
    wrappedLines*: seq[DisplayLine] # Cached wrapped lines
    contentHash*: string            # To detect changes
    height*: int                    # Total lines occupied
    dirty*: bool                    # Needs re-wrap

  StreamingState* = object
    ## State for streaming message updates
    active*: bool
    messageIdx*: int
    lastContent*: string
    lastContentLen*: int
    lastUpdateTime*: MonoTime
    updateCount*: int

  TuiApp* = ref object
    running*: bool
    agentLoop*: AgentLoop
    cfg*: Config
    messages*: seq[ChatMessage]
    cachedMessages*: seq[CachedMessage] # NEW: Cached render state
    inputBuffer*: string
    visualInput*: string
    cursorX*: int
    visualCursorX*: int
    scrollOffset*: int
    needsRedraw*: bool
    needsFullRedraw*: bool              # NEW: Force full redraw
    isGenerating*: bool
    ctrlDCount*: int
    ctrlDHintVisible*: bool
    streaming*: StreamingState          # NEW: Streaming state
    lastRenderTime*: MonoTime           # NEW: For performance monitoring
    renderCount*: int                   # NEW: Debug counter

  ChatMessage* = object
    role*: string
    content*: string
    toolCalls*: seq[providers_types.ToolCall]
    expanded*: bool

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6
  # Throttling for streaming updates
  MinUpdateIntervalMs = 50 # Minimum ms between re-wraps
  MinContentDelta = 10     # Minimum new chars before re-wrap

proc readEventGcsafe(): Event =
  {.gcsafe.}:
    result = readEvent()

proc deinitTextalotGcsafe() =
  {.gcsafe.}:
    deinitTextalot()

proc hashContent(content: string): string =
  ## Simple hash for change detection
  $content.len & "_" & (if content.len > 0: $content[0] else: "") & "_" &
  (if content.len > 0: $content[^1] else: "")

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
    cachedMessages: @[],
    inputBuffer: "",
    visualInput: "",
    cursorX: 0,
    visualCursorX: 0,
    scrollOffset: 0,
    needsRedraw: true,
    needsFullRedraw: true,
    isGenerating: false,
    ctrlDCount: 0,
    ctrlDHintVisible: false,
    streaming: StreamingState(active: false, messageIdx: -1),
    lastRenderTime: getMonoTime(),
    renderCount: 0
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

proc wrapTextToLines(text: string, maxWidth: int, role: string, indent: int): seq[DisplayLine] =
  ## Word wrap with fallback for no-space languages (e.g. CJK)
  ## Returns DisplayLine objects ready for rendering
  result = @[]

  for rawLine in text.splitLines():
    var currentLine = ""
    var currentWidth = 0
    var lineResult: seq[DisplayLine] = @[]

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
        lineResult.add(DisplayLine(
          text: currentLine,
          fgColor: FG_COLOR_DEFAULT,
          bgColor: BG_COLOR_DEFAULT,
          style: STYLE_NONE,
          indent: indent,
          role: role
        ))
        currentLine = word
        currentWidth = wordWidth

    if currentLine.len > 0:
      lineResult.add(DisplayLine(
        text: currentLine,
        fgColor: FG_COLOR_DEFAULT,
        bgColor: BG_COLOR_DEFAULT,
        style: STYLE_NONE,
        indent: indent,
        role: role
      ))
    elif rawLine.len == 0:
      lineResult.add(DisplayLine(
        text: "",
        fgColor: FG_COLOR_DEFAULT,
        bgColor: BG_COLOR_DEFAULT,
        style: STYLE_NONE,
        indent: indent,
        role: role
      ))

    # Handle lines that are still too long (CJK fallback)
    for line in lineResult:
      if stringDisplayWidth(line.text) <= maxWidth:
        result.add(line)
      else:
        var current = ""
        var currentWidth = 0
        for r in line.text.runes:
          let rw = runeDisplayWidth(r)
          if currentWidth + rw > maxWidth:
            result.add(DisplayLine(
              text: current,
              fgColor: FG_COLOR_DEFAULT,
              bgColor: BG_COLOR_DEFAULT,
              style: STYLE_NONE,
              indent: indent,
              role: role
            ))
            current = r.toUTF8
            currentWidth = rw
          else:
            current.add(r.toUTF8)
            currentWidth += rw
        if current.len > 0:
          result.add(DisplayLine(
            text: current,
            fgColor: FG_COLOR_DEFAULT,
            bgColor: BG_COLOR_DEFAULT,
            style: STYLE_NONE,
            indent: indent,
            role: role
          ))

  if result.len == 0:
    result.add(DisplayLine(
      text: "",
      fgColor: FG_COLOR_DEFAULT,
      bgColor: BG_COLOR_DEFAULT,
      style: STYLE_NONE,
      indent: indent,
      role: role
    ))

proc getRoleColor(role: string): uint32 =
  case role:
  of "user": FG_COLOR_CYAN
  of "assistant": FG_COLOR_GREEN
  of "system": FG_COLOR_YELLOW
  of "tool": FG_COLOR_MAGENTA
  else: FG_COLOR_DEFAULT

proc getRolePrefix(role: string): string =
  case role:
  of "user": "You:"
  of "assistant": ">"
  of "system": "⚙"
  of "tool": "🔧"
  else: "•"

proc updateCachedMessage(app: TuiApp, msgIdx: int) =
  ## Update cached display lines for a single message (incremental)
  ## Now with markdown rendering support
  if msgIdx >= app.messages.len:
    return

  let msg = app.messages[msgIdx]
  let contentHash = hashContent(msg.content)

  # Check if cache exists and is up to date
  if msgIdx < app.cachedMessages.len:
    let cached = app.cachedMessages[msgIdx]
    if cached.contentHash == contentHash and not cached.dirty:
      return # Cache hit - nothing to do
  else:
    # Extend cache to include this message
    while app.cachedMessages.len <= msgIdx:
      app.cachedMessages.add(CachedMessage())

  let maxContentWidth = app.chatWidth() - 12
  var wrappedLines: seq[DisplayLine] = @[]

  # Add role indicator line
  let rolePrefix = getRolePrefix(msg.role)
  let roleColor = getRoleColor(msg.role)
  wrappedLines.add(DisplayLine(
    text: rolePrefix,
    fgColor: roleColor,
    bgColor: BG_COLOR_DEFAULT,
    style: STYLE_NONE,
    indent: 0,
    role: msg.role
  ))

  # Parse and render markdown content
  if msg.content.len > 0:
    let parsed = markdown_rendering.parseMarkdown(msg.content)
    let mdLines = markdown_rendering.renderToTerminalLines(parsed, maxContentWidth - 6, 6)

    for line in mdLines:
      wrappedLines.add(DisplayLine(
        text: line.text,
        fgColor: line.fg,
        bgColor: line.bg,
        style: line.style,
        indent: line.indent,
        role: msg.role
      ))

  # Add empty line after message
  wrappedLines.add(DisplayLine(
    text: "",
    fgColor: FG_COLOR_DEFAULT,
    bgColor: BG_COLOR_DEFAULT,
    style: STYLE_NONE,
    indent: 0,
    role: ""
  ))

  # Update cache
  app.cachedMessages[msgIdx] = CachedMessage(
    role: msg.role,
    content: msg.content,
    wrappedLines: wrappedLines,
    contentHash: contentHash,
    height: wrappedLines.len,
    dirty: false
  )

proc getTotalCachedHeight(app: TuiApp): int =
  ## Get total height of all cached messages
  result = 0
  for cached in app.cachedMessages:
    result += cached.height

proc shouldThrottleUpdate(app: TuiApp, content: string): bool =
  ## Check if we should throttle this update (for streaming)
  if not app.streaming.active:
    return false

  let now = getMonoTime()
  let timeSinceLast = (now - app.streaming.lastUpdateTime).inMilliseconds
  let contentDelta = content.len - app.streaming.lastContentLen

  # Throttle if too soon AND not enough new content
  if timeSinceLast < MinUpdateIntervalMs and contentDelta < MinContentDelta:
    return true

  return false

proc handleStreamingUpdate*(app: TuiApp, msgIdx: int, content: string, reasoning: string, isDone: bool) =
  ## Optimized handler for streaming updates from onUpdate callback

  # Initialize streaming state if needed
  if not app.streaming.active:
    app.streaming.active = true
    app.streaming.messageIdx = msgIdx
    app.streaming.lastContent = ""
    app.streaming.lastContentLen = 0
    app.streaming.lastUpdateTime = getMonoTime()
    app.streaming.updateCount = 0

  # Update the message content
  if msgIdx < app.messages.len:
    app.messages[msgIdx].content = content

  # Check if we should process this update or throttle it
  if not isDone and app.shouldThrottleUpdate(content):
    return # Skip this update, wait for next
  
  # Update streaming state
  app.streaming.lastContent = content
  app.streaming.lastContentLen = content.len
  app.streaming.lastUpdateTime = getMonoTime()
  app.streaming.updateCount += 1

  # Mark only the streaming message as dirty
  if msgIdx < app.cachedMessages.len:
    app.cachedMessages[msgIdx].dirty = true

  # For streaming, we do partial redraw (not full)
  app.needsRedraw = true

  # When done, finalize
  if isDone:
    app.streaming.active = false
    app.streaming.messageIdx = -1

proc addMessage(app: TuiApp, role, content: string, toolCalls: seq[providers_types.ToolCall] = @[]) =
  app.messages.add(ChatMessage(
    role: role,
    content: content,
    toolCalls: toolCalls,
    expanded: false
  ))
  # Mark that we need to extend cache for new message
  app.needsFullRedraw = true
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
  app.needsFullRedraw = true
  app.needsRedraw = true

  # Add placeholder message for assistant that will be updated incrementally
  let assistantMsgIdx = app.messages.len
  app.addMessage("assistant", "")

  # Create callback for incremental updates (optimized)
  let onUpdate = proc(content: string, reasoning: string, isDone: bool) {.gcsafe.} =
    {.gcsafe.}:
      if assistantMsgIdx < app.messages.len:
        # Use optimized streaming handler instead of just setting needsRedraw
        app.handleStreamingUpdate(assistantMsgIdx, content, reasoning, isDone)

  let response = await app.agentLoop.processDirect(userInput, "tui:default", onUpdate)

  # Ensure final content is set
  if assistantMsgIdx < app.messages.len:
    app.messages[assistantMsgIdx].content = response
    if assistantMsgIdx < app.cachedMessages.len:
      app.cachedMessages[assistantMsgIdx].dirty = true
  app.isGenerating = false
  app.streaming.active = false
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
      let maxScroll = max(0, app.getTotalCachedHeight() - app.chatHeight())
      if app.scrollOffset < maxScroll:
        app.scrollOffset.inc
        app.needsRedraw = true

    of EVENT_KEY_PGUP:
      app.scrollOffset = max(0, app.scrollOffset - app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_PGDN:
      let maxScroll = max(0, app.getTotalCachedHeight() - app.chatHeight())
      app.scrollOffset = min(maxScroll, app.scrollOffset + app.chatHeight())
      app.needsRedraw = true

    of EVENT_KEY_CTRL_L:
      # Clear screen
      app.messages = @[]
      app.cachedMessages = @[]
      app.scrollOffset = 0
      app.needsFullRedraw = true
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
      let maxScroll = max(0, app.getTotalCachedHeight() - app.chatHeight())
      if app.scrollOffset < maxScroll:
        app.scrollOffset.inc
      app.needsRedraw = true
    else:
      discard

  elif ev of ResizeEvent:
    {.gcsafe.}:
      recreateBuffers()
    # Resize requires full recalculation
    app.needsFullRedraw = true
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

proc renderChatIncremental(app: TuiApp) =
  ## Incremental chat rendering - only updates changed/dirty messages
  let w = app.chatWidth()
  let h = app.chatHeight()
  let startY = HeaderHeight + 1
  let maxContentWidth = w - 12

  # Clear chat area only on full redraw
  if app.needsFullRedraw:
    removeArea(0, startY, w, startY + h)

  # Build/update cache for all visible messages
  var totalHeight = 0
  for i in 0..<app.messages.len:
    app.updateCachedMessage(i)
    totalHeight += app.cachedMessages[i].height

  # Calculate visible range based on scroll offset
  let visibleStart = app.scrollOffset
  let visibleEnd = visibleStart + h

  # Collect all lines that need to be displayed
  var allLines: seq[DisplayLine] = @[]
  var currentLineIdx = 0

  for i in 0..<app.cachedMessages.len:
    let cached = app.cachedMessages[i]
    let msgStart = currentLineIdx
    let msgEnd = currentLineIdx + cached.height

    # Skip if message is entirely outside visible range
    if msgEnd < visibleStart or msgStart > visibleEnd:
      currentLineIdx = msgEnd
      continue

    # Add visible lines from this message
    let lineStart = max(0, visibleStart - msgStart)
    let lineEnd = min(cached.height, visibleEnd - msgStart)

    for j in lineStart..<lineEnd:
      if j < cached.wrappedLines.len:
        allLines.add(cached.wrappedLines[j])

    currentLineIdx = msgEnd

  # Draw from bottom up
  var currentY = startY + h - 1

  # Draw Ctrl+D hint at the bottom of chat area if visible
  if app.ctrlDHintVisible and currentY >= startY:
    let hint = "⚠ Press Ctrl+D again to exit"
    drawTextWide(hint, 2, currentY, FG_COLOR_YELLOW, BG_COLOR_DEFAULT, STYLE_FAINT)
    currentY.dec

  # Draw visible lines
  for i in countdown(allLines.len - 1, 0):
    if currentY < startY: break

    let line = allLines[i]
    if line.text.len > 0:
      # Get color based on role
      var fg = line.fgColor
      if fg == FG_COLOR_DEFAULT:
        fg = getRoleColor(line.role)
      drawTextWide(line.text, line.indent, currentY, fg, line.bgColor, line.style)

    currentY.dec

  # Reset full redraw flag
  app.needsFullRedraw = false

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

  # Performance tracking
  app.renderCount += 1
  let renderStart = getMonoTime()

  {.gcsafe.}:
    # Only clear full screen on full redraw
    if app.needsFullRedraw:
      removeArea(0, 0, w, h)

    app.renderHeader()
    app.renderChatIncremental() # Use incremental rendering
    app.renderInput()
    texalotRender()
    app.positionCursor()

  app.needsRedraw = false

  # Track render time
  let renderEnd = getMonoTime()
  app.lastRenderTime = renderEnd

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
