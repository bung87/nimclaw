import std/[strutils, unicode, times, monotimes, osproc, os]
import std/terminal except showCursor, hideCursor
import textalot
import chronos
import ../providers/types as providers_types
import ../agent/loop
import ../config
import ../logger
import ../persona/manager as persona_manager
import ../session
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

  CommandMenu* = object
    ## Slash command menu state
    visible*: bool
    selectedIndex*: int
    commands*: seq[CommandItem]

  CommandItem* = object
    name*: string
    description*: string
    fullCmd*: string

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
    sessionKey*: string                 # Current session key
    sessionCounter*: int                # For generating new session keys
    cmdMenu*: CommandMenu               # Slash command menu

  ChatMessage* = object
    role*: string
    content*: string
    thinking*: string # Reasoning/thinking content (rendered in grey)
    toolCalls*: seq[providers_types.ToolCall]
    expanded*: bool

const
  HeaderHeight = 2
  InputHeight = 3
  InputStartX = 6
  # Throttling for streaming updates
  MinUpdateIntervalMs = 50 # Minimum ms between re-wraps
  MinContentDelta = 10     # Minimum new chars before re-wrap

  # Available slash commands
  SlashCommands = [
    CommandItem(name: "new", description: "Start a new session", fullCmd: "/new"),
    CommandItem(name: "persona list", description: "List all personas", fullCmd: "/persona list"),
    CommandItem(name: "persona switch", description: "Switch to a persona (you'll type the name)",
        fullCmd: "/persona switch "),
    CommandItem(name: "persona create", description: "Create new persona (you'll type the name)",
        fullCmd: "/persona create "),
    CommandItem(name: "persona edit", description: "Edit a persona in external editor",
        fullCmd: "/persona edit "),
    CommandItem(name: "quit", description: "Exit nimclaw", fullCmd: "/quit"),
    CommandItem(name: "exit", description: "Exit nimclaw", fullCmd: "/exit"),
    CommandItem(name: "clear", description: "Clear the screen", fullCmd: "/clear"),
    CommandItem(name: "undo", description: "Undo last turn", fullCmd: "(Ctrl+U)")
  ]

proc readEventGcsafe(): Event =
  {.gcsafe.}:
    result = readEvent()

proc deinitTextalotGcsafe() =
  {.gcsafe.}:
    deinitTextalot()

proc hashContent(content: string): string =
  ## Better hash for change detection using checksum
  if content.len == 0:
    return "0"

  # Simple but effective hash: combine length with sum of bytes
  var sum = content.len.uint32
  for i in 0..<min(content.len, 1000): # Sample first 1000 chars
    sum = sum * 31 + content[i].uint32

  # Also sample from end
  for i in max(0, content.len - 100)..<content.len:
    sum = sum * 31 + content[i].uint32

  result = $content.len & "_" & $sum

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
    renderCount: 0,
    sessionKey: "tui:default",
    sessionCounter: 1
  )

proc chatHeight(app: TuiApp): int =
  getTerminalHeight() - HeaderHeight - InputHeight - 1

proc chatWidth(app: TuiApp): int =
  getTerminalWidth()

# Calculate visible portion of input
proc updateVisualInput(app: TuiApp) =
  let maxWidth = getTerminalWidth() - InputStartX - 4
  let totalRunes = app.inputBuffer.runeLen

  # Ensure cursorX is within valid bounds (cursorX is byte position)
  if app.cursorX < 0:
    app.cursorX = 0
  if app.cursorX > app.inputBuffer.len:
    app.cursorX = app.inputBuffer.len

  let cursorRunes = if app.cursorX > 0: app.inputBuffer[0..<app.cursorX].runeLen else: 0

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

# Command Menu Functions

proc showCommandMenu(app: TuiApp) =
  ## Show the slash command menu
  app.cmdMenu.visible = true
  app.cmdMenu.selectedIndex = 0
  app.cmdMenu.commands = @SlashCommands
  app.needsRedraw = true

proc hideCommandMenu(app: TuiApp) =
  ## Hide the command menu
  app.cmdMenu.visible = false
  app.cmdMenu.selectedIndex = 0
  app.needsRedraw = true

proc selectNextCommand(app: TuiApp) =
  ## Move selection down
  if app.cmdMenu.commands.len > 0:
    app.cmdMenu.selectedIndex = (app.cmdMenu.selectedIndex + 1) mod app.cmdMenu.commands.len
    app.needsRedraw = true

proc selectPrevCommand(app: TuiApp) =
  ## Move selection up
  if app.cmdMenu.commands.len > 0:
    app.cmdMenu.selectedIndex = (app.cmdMenu.selectedIndex - 1 + app.cmdMenu.commands.len) mod app.cmdMenu.commands.len
    app.needsRedraw = true

proc sendMessage(app: TuiApp) {.async.}

proc executeSelectedCommand(app: TuiApp) {.async.} =
  ## Execute the selected command
  if app.cmdMenu.selectedIndex < app.cmdMenu.commands.len:
    let cmd = app.cmdMenu.commands[app.cmdMenu.selectedIndex]
    app.inputBuffer = cmd.fullCmd
    app.cursorX = app.inputBuffer.len
    app.updateVisualInput()
    app.hideCommandMenu()

    # Auto-execute certain commands
    if cmd.name in ["new", "quit", "exit", "clear"]:
      await app.sendMessage()

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
  let contentHash = hashContent(msg.thinking & "\0" & msg.content)

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

  # Render thinking content (grey/faint)
  if msg.thinking.len > 0:
    let thinkingParsed = markdown_rendering.parseMarkdown(msg.thinking)
    let thinkingLines = markdown_rendering.renderToTerminalLines(thinkingParsed, maxContentWidth - 8, 8)

    # Add "Thinking:" header
    wrappedLines.add(DisplayLine(
      text: "💭 Thinking:",
      fgColor: markdown_rendering.ThinkingFg,
      bgColor: BG_COLOR_DEFAULT,
      style: STYLE_FAINT,
      indent: 6,
      role: msg.role
    ))

    for line in thinkingLines:
      wrappedLines.add(DisplayLine(
        text: line.text,
        fgColor: markdown_rendering.ThinkingFg,
        bgColor: line.bg,
        style: STYLE_FAINT,
        indent: line.indent,
        role: msg.role
      ))
    # Empty line after thinking
    wrappedLines.add(DisplayLine(
      text: "",
      fgColor: FG_COLOR_DEFAULT,
      bgColor: BG_COLOR_DEFAULT,
      style: STYLE_NONE,
      indent: 0,
      role: ""
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

proc handleStreamingUpdate*(app: TuiApp, msgIdx: int, thinking: string, response: string, isDone: bool) =
  ## Optimized handler for streaming updates from onUpdate callback

  # Initialize streaming state if needed
  if not app.streaming.active:
    app.streaming.active = true
    app.streaming.messageIdx = msgIdx
    app.streaming.lastContent = ""
    app.streaming.lastContentLen = 0
    app.streaming.lastUpdateTime = getMonoTime()
    app.streaming.updateCount = 0

  # Update the message content (separate thinking and response)
  if msgIdx < app.messages.len:
    app.messages[msgIdx].thinking = thinking
    app.messages[msgIdx].content = response

  # Check if we should process this update or throttle it
  let combined = thinking & response
  if not isDone and app.shouldThrottleUpdate(combined):
    return # Skip this update, wait for next
  
  # Update streaming state
  app.streaming.lastContent = combined
  app.streaming.lastContentLen = combined.len
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

proc handlePersonaCommand(app: TuiApp, input: string) {.async.} =
  ## Handle /persona commands
  let parts = strutils.splitWhitespace(input)
  let cmd = if parts.len > 1: parts[1].toLowerAscii() else: ""

  let pm = app.agentLoop.contextBuilder.personaManager

  case cmd:
    of "", "help":
      let helpText = """Persona commands:
/persona - Show active persona
/persona list - List all personas
/persona switch <name> - Switch to persona
/persona create <name> - Create new persona (interactive)
/persona show <name> - Show persona details
/persona delete <name> - Delete a persona"""
      app.addMessage("system", helpText)

    of "list":
      let personas = pm.listPersonas()
      if personas.len == 0:
        app.addMessage("system", "No personas found. Use '/persona create <name>' to create one.")
      else:
        var listText = "Available personas:\n"
        let active = pm.getActivePersona(app.sessionKey)
        for slug in personas:
          let marker = if slug == active.slug: " [active]" else: ""
          listText.add("- " & slug & marker & "\n")
        app.addMessage("system", listText)

    of "switch":
      if parts.len < 3:
        app.addMessage("system", "Usage: /persona switch <name>")
      else:
        let name = parts[2]
        try:
          pm.setActivePersona(app.sessionKey, name)
          let persona = pm.loadPersona(name)
          app.addMessage("system", "Switched to persona: " & persona.name)
        except persona_manager.PersonaError as e:
          app.addMessage("system", "Error: " & e.msg)

    of "create":
      if parts.len < 3:
        app.addMessage("system", "Usage: /persona create <name>")
      else:
        let name = parts[2..^1].join(" ")
        let lowerName: string = name.toLowerAscii()
        var slug = strutils.splitWhitespace(lowerName).join("-")
        # Remove non-alphanumeric characters (except hyphen)
        var cleanSlug = ""
        for c in slug:
          if c in {'a'..'z', '0'..'9', '-'}:
            cleanSlug.add(c)
        slug = cleanSlug

        if pm.personaExists(slug):
          app.addMessage("system", "Persona '" & slug & "' already exists.")
          return

        # Create basic persona
        let persona = persona_manager.Persona(
          name: name,
          slug: slug,
          soul: "# Soul\n\nI am " & name & ", a helpful AI assistant.\n\n## Personality\n- Helpful and efficient\n- Clear communication\n",
          identity: "# Identity\n\nName: " & name & "\nRole: AI Assistant\n",
          agents: "# Agent Instructions\n\nYou are a helpful AI assistant.",
          user: "",
          metadata: persona_manager.PersonaMetadata(
            temperature: 0.7,
            createdAt: getTime().toUnix(),
            updatedAt: getTime().toUnix()
          )
        )

        try:
          pm.savePersona(persona)
          app.addMessage("system", "Created persona: " & name & " (slug: " & slug & ")")
          app.addMessage("system", "Edit files in ~/.nimclaw/workspace/personas/" & slug & "/ to customize.")
        except CatchableError as e:
          app.addMessage("system", "Error creating persona: " & e.msg)

    of "show", "get":
      if parts.len < 3:
        app.addMessage("system", "Usage: /persona show <name>")
      else:
        let name = parts[2]
        try:
          let persona = pm.loadPersona(name)
          var info = "Persona: " & persona.name & " (" & persona.slug & ")\n"
          if persona.metadata.model.len > 0:
            info.add("Model: " & persona.metadata.model & "\n")
          info.add("Temperature: " & $persona.metadata.temperature & "\n")
          info.add("\nFiles:\n")
          info.add("- SOUL.md: " & (if persona.soul.len > 0: $persona.soul.len & " chars" else: "empty") & "\n")
          info.add("- IDENTITY.md: " & (if persona.identity.len > 0: $persona.identity.len & " chars" else: "empty") & "\n")
          info.add("- AGENTS.md: " & (if persona.agents.len > 0: $persona.agents.len & " chars" else: "empty") & "\n")
          app.addMessage("system", info)
        except persona_manager.PersonaError as e:
          app.addMessage("system", "Error: " & e.msg)

    of "delete":
      if parts.len < 3:
        app.addMessage("system", "Usage: /persona delete <name>")
      else:
        let name = parts[2]
        try:
          pm.deletePersona(name)
          app.addMessage("system", "Deleted persona: " & name)
        except persona_manager.PersonaError as e:
          app.addMessage("system", "Error: " & e.msg)

    of "edit":
      if parts.len < 3:
        app.addMessage("system", "Usage: /persona edit <name>")
      else:
        let name = parts[2]
        try:
          let persona = pm.loadPersona(name)
          let personaDir = pm.personasDir / persona.slug

          # Try $EDITOR first, then fall back to platform default
          let editor = getEnv("EDITOR", "")
          var cmd = ""

          if editor != "":
            # Use user's preferred editor
            cmd = editor & " \"" & personaDir & "\""
            app.addMessage("system", "Opening " & persona.name & " persona in " & editor & "...")
          else:
            # Use platform default application
            when defined(macosx):
              cmd = "open \"" & personaDir & "\""
            elif defined(windows):
              cmd = "start \"\" \"" & personaDir & "\""
            else:
              # Linux and other Unix
              cmd = "xdg-open \"" & personaDir & "\""
            app.addMessage("system", "Opening " & persona.name & " persona...")

          # Run in background so TUI isn't blocked
          when defined(windows):
            discard startProcess("cmd", args = ["/c", cmd], options = {poDaemon})
          else:
            discard startProcess("sh", args = ["-c", cmd], options = {poDaemon})
        except persona_manager.PersonaError as e:
          app.addMessage("system", "Error: " & e.msg)

    else:
      app.addMessage("system", "Unknown persona command: " & cmd & ". Type /persona for help.")

  app.inputBuffer = ""
  app.cursorX = 0
  app.updateVisualInput()
  app.needsFullRedraw = true
  app.needsRedraw = true

proc sendMessage(app: TuiApp) {.async.} =
  let userInput = app.inputBuffer.strip()
  if userInput.len == 0: return

  # Handle quit command
  if userInput.toLowerAscii() in ["quit", "exit", "q"]:
    app.running = false
    return

  # Handle /new command to create a fresh session
  if userInput.strip() == "/new":
    app.sessionCounter += 1
    app.sessionKey = "tui:default:" & $app.sessionCounter
    app.messages = @[]
    app.cachedMessages = @[]
    app.inputBuffer = ""
    app.cursorX = 0
    app.updateVisualInput()
    app.needsFullRedraw = true
    app.needsRedraw = true
    return

  # Handle /persona commands
  if userInput.startsWith("/persona"):
    await app.handlePersonaCommand(userInput)
    return

  # Handle /clear command
  if userInput.strip() == "/clear":
    app.messages = @[]
    app.cachedMessages = @[]
    app.scrollOffset = 0
    app.needsFullRedraw = true
    app.needsRedraw = true
    app.inputBuffer = ""
    app.cursorX = 0
    app.updateVisualInput()
    return

  # Handle /undo command
  if userInput.strip() == "/undo":
    if not app.isGenerating:
      let popped = app.agentLoop.sessions.popRecord(app.sessionKey, 2)
      if popped.len > 0:
        # Remove last user message from UI
        if app.messages.len >= 2:
          app.messages.setLen(app.messages.len - 2)
          app.cachedMessages.setLen(app.cachedMessages.len - 2)
        app.addMessage("system", "Undid last turn (" & $popped.len & " messages)")
      else:
        app.addMessage("system", "Nothing to undo")
      app.needsFullRedraw = true
      app.needsRedraw = true
    app.inputBuffer = ""
    app.cursorX = 0
    app.updateVisualInput()
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

  # Callback receives thinking and response separately for proper styling
  let onUpdate = proc(thinking: string, response: string, isDone: bool) {.gcsafe.} =
    {.gcsafe.}:
      if assistantMsgIdx < app.messages.len:
        app.handleStreamingUpdate(assistantMsgIdx, thinking, response, isDone)

  var response = ""
  try:
    response = await app.agentLoop.processDirect(userInput, app.sessionKey, onUpdate)
  except CatchableError as e:
    error "processDirect failed", topic = "tui", error = e.msg, session = app.sessionKey
    response = "Error: " & e.msg

  # Ensure final content is set
  if assistantMsgIdx < app.messages.len:
    app.messages[assistantMsgIdx].content = response
    if assistantMsgIdx < app.cachedMessages.len:
      app.cachedMessages[assistantMsgIdx].dirty = true
  app.isGenerating = false
  app.streaming.active = false
  app.needsRedraw = true

proc deleteRuneBefore(app: TuiApp) =
  ## Delete the rune before the cursor position
  if app.cursorX <= 0 or app.inputBuffer.len == 0:
    return

  var newBuffer = ""
  var currentPos = 0
  var deleted = false
  for r in app.inputBuffer.runes:
    let rstr = r.toUTF8
    if not deleted and currentPos + rstr.len == app.cursorX:
      # This is the rune to delete (it's before the cursor)
      app.cursorX = currentPos
      deleted = true
      # Skip adding this rune to newBuffer
    else:
      newBuffer.add(rstr)
    currentPos += rstr.len
  app.inputBuffer = newBuffer

proc deleteRuneAt(app: TuiApp) =
  ## Delete the rune at the cursor position (forward delete)
  # cursorX is byte position, so compare with byte length
  if app.cursorX >= app.inputBuffer.len or app.inputBuffer.len == 0:
    return

  var newBuffer = ""
  var currentPos = 0
  var deleted = false
  for r in app.inputBuffer.runes:
    let rstr = r.toUTF8
    if not deleted and currentPos == app.cursorX:
      # This is the rune to delete (at cursor position)
      deleted = true
      # Skip adding this rune to newBuffer
    else:
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

proc handleEvent(app: TuiApp, ev: Event) {.async.} =
  if ev of KeyEvent:
    let kev = cast[KeyEvent](ev)
    let key = kev.key

    if key != EVENT_KEY_CTRL_D:
      app.ctrlDCount = 0
      if app.ctrlDHintVisible:
        app.ctrlDHintVisible = false
        app.needsRedraw = true

    # Handle command menu navigation when visible
    if app.cmdMenu.visible:
      case key
      of EVENT_KEY_ESC:
        app.hideCommandMenu()
        return
      of EVENT_KEY_ENTER:
        await app.executeSelectedCommand()
        return
      of EVENT_KEY_ARROW_UP:
        app.selectPrevCommand()
        return
      of EVENT_KEY_ARROW_DOWN:
        app.selectNextCommand()
        return
      else:
        # Hide menu on any other key, but still process the key
        app.hideCommandMenu()

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

    of EVENT_KEY_CTRL_U:
      # Undo last turn (pop last 2 records: assistant + user)
      if not app.isGenerating:
        let popped = app.agentLoop.sessions.popRecord(app.sessionKey, 2)
        if popped.len > 0:
          # Remove last user message from UI
          if app.messages.len >= 2:
            app.messages.setLen(app.messages.len - 2)
            app.cachedMessages.setLen(app.cachedMessages.len - 2)
          app.addMessage("system", "Undid last turn (" & $popped.len & " messages)")
          app.needsFullRedraw = true
          app.needsRedraw = true

    else:
      # Handle printable characters (ASCII + Unicode)
      if key >= 0x20 and key <= 0x10FFFF'u32:
        let c = Rune(key.int).toUTF8()
        # Check if this is '/' at start of empty input -> show command menu
        if c == "/" and app.inputBuffer.len == 0 and app.cursorX == 0:
          app.inputBuffer.insert(c, app.cursorX)
          app.cursorX += c.len
          app.updateVisualInput()
          app.showCommandMenu()
        else:
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

  # Clear chat area to prevent artifacts from previous renders
  # This is necessary because content length can change during streaming
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

  # Clear input area first to prevent ghost characters
  removeArea(0, inputY, w, inputY + 1)

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

proc renderCommandMenu(app: TuiApp) =
  ## Render the slash command menu
  if not app.cmdMenu.visible: return

  let w = getTerminalWidth()
  let h = getTerminalHeight()

  # Menu dimensions
  let menuWidth = min(60, w - 4)
  let itemCount = app.cmdMenu.commands.len
  let menuHeight = min(itemCount + 2, h div 2) # +2 for border, max half screen
  let menuX = max(2, (w - menuWidth) div 2)
  let menuY = max(2, h - menuHeight - 5) # Position above input area

  # Draw menu background/border
  drawRectangle(menuX, menuY, menuX + menuWidth, menuY + menuHeight, BG_COLOR_DEFAULT, FG_COLOR_DEFAULT, " ", STYLE_NONE)

  # Menu title
  let title = " Commands "
  let titleX = menuX + (menuWidth - title.len) div 2
  drawTextWide(title, titleX, menuY, FG_COLOR_CYAN, BG_COLOR_DEFAULT, STYLE_BOLD)
  drawTextWide("┌" & "─".repeat(menuWidth - 2) & "┐", menuX, menuY, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_FAINT)
  drawTextWide("└" & "─".repeat(menuWidth - 2) & "┘", menuX, menuY + menuHeight - 1, FG_COLOR_DEFAULT,
      BG_COLOR_DEFAULT, STYLE_FAINT)

  # Draw commands
  let visibleItems = min(itemCount, menuHeight - 2)
  let startIdx = max(0, min(app.cmdMenu.selectedIndex - visibleItems div 2, itemCount - visibleItems))

  for i in 0..<visibleItems:
    let cmdIdx = startIdx + i
    if cmdIdx >= itemCount: break

    let cmd = app.cmdMenu.commands[cmdIdx]
    let y = menuY + 1 + i
    let isSelected = cmdIdx == app.cmdMenu.selectedIndex

    # Clear line
    drawTextWide(" ".repeat(menuWidth - 2), menuX + 1, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE)

    if isSelected:
      # Highlight selected item
      drawTextWide(" ".repeat(menuWidth - 2), menuX + 1, y, FG_COLOR_DEFAULT, FG_COLOR_CYAN, STYLE_NONE)
      drawTextWide("▶ " & cmd.fullCmd, menuX + 2, y, FG_COLOR_BLACK, FG_COLOR_CYAN, STYLE_BOLD)
      # Description on the right (truncated if needed)
      let descMaxLen = menuWidth - cmd.fullCmd.len - 8
      if descMaxLen > 5:
        let desc = if cmd.description.len > descMaxLen: cmd.description[0..<descMaxLen] & "..." else: cmd.description
        drawTextWide(desc, menuX + menuWidth - desc.len - 2, y, FG_COLOR_BLACK, FG_COLOR_CYAN, STYLE_NONE)
    else:
      # Normal item
      drawTextWide("  " & cmd.fullCmd, menuX + 2, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE)
      # Description (dim)
      let descMaxLen = menuWidth - cmd.fullCmd.len - 8
      if descMaxLen > 5:
        let desc = if cmd.description.len > descMaxLen: cmd.description[0..<descMaxLen] & "..." else: cmd.description
        drawTextWide(desc, menuX + menuWidth - desc.len - 2, y, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_FAINT)

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
    app.renderCommandMenu() # Render command menu if visible
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
    await app.handleEvent(ev)

    if app.needsRedraw:
      app.render()

    await sleepAsync(20 * Millisecond)

  deinitTextalotGcsafe()

proc cleanup*() {.noconv.} =
  deinitTextalot()
