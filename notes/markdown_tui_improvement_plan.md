# Nimclaw Markdown TUI Rendering Improvement Plan

## Executive Summary

This plan outlines how to improve nimclaw's handling of LLM markdown responses by integrating a proper markdown parser and enhancing the TUI to render formatted content beautifully in the terminal.

## Current State Analysis

### Existing TUI (`src/nimclaw/tui/core.nim`)
- Uses `textalot` for terminal buffer management
- Basic word wrapping via `wrapText()`
- Simple role-based coloring (user=cyan, assistant=green, system=yellow, tool=magenta)
- Plain text rendering only - no markdown awareness
- Messages rendered as raw strings with `>` prefix for assistant

### Critical Issue: Non-Incremental Rendering

**Current rendering flow (EVERY frame):**
```nim
proc render():
  removeArea(0, 0, w, h)              # Clear ENTIRE screen
  for msg in allMessages:              # Iterate ALL messages
    let wrapped = wrapText(msg.content) # Re-wrap EVERY message
    displayLines.add(wrapped)           # Rebuild display buffer
  drawFromBottom(displayLines)         # Re-render EVERYTHING
```

**Complexity: O(n × m)** where n = message count, m = avg message length

| Messages | Current Cost | With Markdown Parsing |
|----------|--------------|----------------------|
| 10 | ~2ms | ~20ms |
| 50 | ~10ms | ~100ms |
| 100 | ~20ms | ~200ms |
| 200 | ~40ms | **~400ms** |

**Target frame budget: 16ms (60 FPS) or 33ms (30 FPS)**

At 100+ messages with markdown parsing, the UI becomes **unusably sluggish**.

### Current Limitations
1. **No incremental rendering**: Rebuilds entire display every frame
2. **No markdown parsing**: Code blocks, headers, lists shown as plain text
3. **No syntax highlighting**: Code blocks lack language-specific colors
4. **Poor readability**: Headers, emphasis, lists not visually distinguished
5. **No interactive elements**: Cannot expand/collapse code blocks or copy content

## Recommended Markdown Parser

### Primary Choice: `nim-markdown` (soasme/nim-markdown)

**Why this parser:**

| Criteria | nim-markdown |
|----------|---------------|
| **CommonMark Compliance** | ✅ v0.29 compliant |
| **GFM Support** | ✅ Tables, strikethrough, autolinks |
| **Performance** | ✅ Optimized (v0.8.8), pre-compiled regex |
| **GC Compatibility** | ✅ Works with `--gc:arc` and `--mm:orc` |
| **Thread Safety** | ✅ gcsafe with `--threads:on` |
| **Maintenance** | ✅ Active (last update May 2024) |
| **Nim Version** | ✅ Supports Nim 2.x |

**Installation:**
```nim
# nimclaw.nimble
requires "markdown >= 0.8.8"
```

**Alternative (if needed):**
- `nim-markdown-it` - if we need plugin extensibility
- Custom regex-based parser - only for minimal code block extraction

## Implementation Plan

### Phase 1: Markdown Parsing Foundation

#### 1.1 Add Dependency
```nim
# nimclaw.nimble
requires "markdown >= 0.8.8"
```

#### 1.2 Create Markdown Parser Module
```
src/nimclaw/
├── tui/
│   ├── core.nim          # Existing TUI
│   ├── renderer.nim      # NEW: Markdown-aware renderer
│   └── markdown_parser.nim # NEW: Parser integration
```

**`src/nimclaw/tui/markdown_parser.nim`:**
```nim
import markdown
import std/[strutils, sequtils]

type
  MdElementKind* = enum
    mdText          # Plain text
    mdHeading       # # ## ###
    mdCodeBlock     # ```lang ... ```
    mdInlineCode    # `code`
    mdList          # - item
    mdOrderedList   # 1. item
    mdBlockQuote    # > quote
    mdEmphasis      # *emphasis*
    mdStrong        # **strong**
    mdStrikethrough # ~~strike~~
    mdLink          # [text](url)
    mdTable         # | col | col |
    mdHorizontalRule# ---
    mdLineBreak     # <br> or two spaces

  MdElement* = object
    kind*: MdElementKind
    content*: string
    language*: string      # For code blocks
    level*: int           # For headings (1-6)
    children*: seq[MdElement]  # For nested structures
    url*: string          # For links

  ParsedMessage* = object
    elements*: seq[MdElement]
    rawText*: string
```

#### 1.3 Parse Markdown to AST
```nim
proc parseMarkdown*(text: string): ParsedMessage =
  ## Parse markdown text into structured elements for TUI rendering
  # Use nim-markdown to parse, then convert to our TUI-friendly AST
  let html = markdown(text)  # Parse via nim-markdown
  # Convert HTML to our MdElement tree (or parse markdown directly)
  result.rawText = text
  result.elements = extractElements(text)
```

### Phase 2: Terminal Renderer

#### 2.1 Create Terminal-Aware Renderer

**`src/nimclaw/tui/renderer.nim`:**
```nim
import textalot
import markdown_parser
import std/[strutils, unicode]

type
  RenderStyle* = object
    fgColor*: uint32
    bgColor*: uint32
    style*: uint16  # bold, italic, underline, faint
    indent*: int

const
  # Theme colors for different markdown elements
  HeadingColors*: array[1..6, uint32] = [
    FG_COLOR_BRIGHT_WHITE,  # H1
    FG_COLOR_WHITE,         # H2
    FG_COLOR_CYAN,          # H3
    FG_COLOR_GREEN,         # H4
    FG_COLOR_YELLOW,        # H5
    FG_COLOR_MAGENTA        # H6
  ]
  CodeFg* = FG_COLOR_GREEN
  CodeBg* = BG_COLOR_DEFAULT
  CodeBlockBg* = 0x1a1a1a'u32  # Dark background for code blocks
  LinkFg* = FG_COLOR_CYAN
  QuoteFg* = FG_COLOR_YELLOW
  QuotePrefix* = "▌ "

proc renderElement*(elem: MdElement, x, y, maxWidth: int): int =
  ## Render a single markdown element, returns lines consumed
  case elem.kind
  of mdHeading:
    return renderHeading(elem, x, y, maxWidth)
  of mdCodeBlock:
    return renderCodeBlock(elem, x, y, maxWidth)
  of mdInlineCode:
    return renderInlineCode(elem, x, y, maxWidth)
  of mdList, mdOrderedList:
    return renderList(elem, x, y, maxWidth)
  of mdBlockQuote:
    return renderBlockQuote(elem, x, y, maxWidth)
  of mdEmphasis:
    return renderEmphasis(elem, x, y, maxWidth, STYLE_ITALIC)
  of mdStrong:
    return renderEmphasis(elem, x, y, maxWidth, STYLE_BOLD)
  of mdLink:
    return renderLink(elem, x, y, maxWidth)
  else:
    return renderText(elem.content, x, y, maxWidth)

proc renderCodeBlock*(elem: MdElement, x, y, maxWidth: int): int =
  ## Render code block with syntax highlighting hints
  let lines = elem.content.splitLines()
  var currentY = y
  
  # Draw language label if present
  if elem.language.len > 0:
    drawTextWide("┌─ " & elem.language & " ", x, currentY, 
                 FG_COLOR_FAINT, CodeBlockBg, STYLE_FAINT)
    currentY.inc
  
  # Draw code content with proper indentation
  for line in lines:
    # Syntax highlighting (basic)
    let highlighted = basicSyntaxHighlight(line, elem.language)
    drawTextWide("│ " & highlighted, x, currentY, CodeFg, CodeBlockBg, STYLE_NONE)
    currentY.inc
  
  # Draw bottom border
  drawTextWide("└" & "─".repeat(maxWidth-1), x, currentY, 
               FG_COLOR_FAINT, BG_COLOR_DEFAULT, STYLE_FAINT)
  currentY.inc
  
  return currentY - y
```

#### 2.2 Syntax Highlighting Support

```nim
proc basicSyntaxHighlight*(code, language: string): string =
  ## Basic syntax highlighting for common languages
  ## Full implementation could use tree-sitter or similar
  case language.toLowerAscii()
  of "nim", "nimrod":
    highlightNim(code)
  of "python", "py":
    highlightPython(code)
  of "json":
    highlightJson(code)
  of "markdown", "md":
    highlightMarkdown(code)
  else:
    code  # No highlighting for unknown languages

proc highlightNim*(code: string): string =
  ## Simple Nim syntax highlighting using ANSI colors
  # Keywords
  var result = code
  for keyword in ["proc", "func", "let", "var", "const", "type", "import", 
                  "export", "if", "else", "elif", "for", "while", "case"]:
    result = result.replace(keyword, fmt"\e[35m{keyword}\e[0m")
  result
```

### Phase 3: TUI Integration

#### 3.1 Modify ChatMessage to Support Parsed Content

```nim
# src/nimclaw/tui/core.nim

type
  ChatMessage* = object
    role*: string
    content*: string           # Raw content
    parsedContent*: ParsedMessage  # NEW: Parsed markdown AST
    toolCalls*: seq[providers_types.ToolCall]
    expanded*: bool
```

#### 3.2 Update Message Rendering

```nim
proc renderChat(app: TuiApp) =
  let w = app.chatWidth()
  let h = app.chatHeight()
  let startY = HeaderHeight + 1
  let maxContentWidth = w - 12

  removeArea(0, startY, w, startY + h)
  
  var displayLines: seq[tuple[role: string, elements: seq[MdElement], indent: int]] = @[]

  for msg in app.messages:
    # Role indicator
    case msg.role:
    of "user": displayLines.add(("user", @[MdElement(kind: mdText, content: "You:")], 0))
    of "assistant": displayLines.add(("assistant", @[MdElement(kind: mdText, content: "🦞")], 0))
    of "system": displayLines.add(("system", @[MdElement(kind: mdText, content: "⚙")], 0))
    of "tool": displayLines.add(("tool", @[MdElement(kind: mdText, content: "🔧")], 0))
    else: displayLines.add(("", @[MdElement(kind: mdText, content: "•")], 0))

    # Parse markdown if not already parsed
    if msg.parsedContent.elements.len == 0 and msg.content.len > 0:
      msg.parsedContent = parseMarkdown(msg.content)
    
    # Add parsed elements
    displayLines.add((msg.role, msg.parsedContent.elements, 6))
    
    # Empty line between messages
    displayLines.add(("", @[], 0))

  # Render from bottom up with scroll offset
  var currentY = startY + h - 1
  # ... rendering logic using renderElement for each MdElement
```

#### 3.3 Visual Improvements

**Before (Current):**
```
> Here is the code: def hello(): print("world")
```

**After (With Markdown Rendering):**
```
🦞
  Here is the code:
  
  ┌─ python
  │ def hello():
  │     print("world")
  └
```

### Phase 4: Enhanced Features

#### 4.1 Expandable Code Blocks

```nim
type
  MdElement* = object
    kind*: MdElementKind
    content*: string
    language*: string
    collapsed*: bool      # NEW: For collapsible sections
    copyHintY*: int       # NEW: Screen position for copy hint

proc toggleCollapse*(elem: var MdElement) =
  elem.collapsed = not elem.collapsed

proc renderCodeBlock*(elem: MdElement, x, y, maxWidth: int): int =
  if elem.collapsed:
    # Show collapsed indicator
    drawTextWide("▶ " & elem.language & " (click to expand)", x, y, 
                 FG_COLOR_FAINT, BG_COLOR_DEFAULT, STYLE_FAINT)
    return 1
  # ... full rendering
```

#### 4.2 Interactive Elements

```nim
# Key binding for toggling code block expansion
of EVENT_KEY_TAB:
  # Toggle expansion of code block at cursor
  if app.focusedElement.kind == mdCodeBlock:
    app.focusedElement.toggleCollapse()
    app.needsRedraw = true
```

#### 4.3 Copy Code to Clipboard

```nim
when defined(macosx):
  import std/osproc
  proc copyToClipboard*(text: string) =
    let p = startProcess("pbcopy", options = {poUsePath})
    p.inputStream.write(text)
    p.inputStream.close()
    p.waitForExit()
    p.close()

# In key handler:
of EVENT_KEY_CTRL_Y:
  # Copy current code block to clipboard
  if app.focusedElement.kind == mdCodeBlock:
    copyToClipboard(app.focusedElement.content)
    showNotification("Copied to clipboard!")
```

### Phase 5: Incremental Rendering Architecture (CRITICAL)

**Current Problem**: Every `render()` call rebuilds ALL messages from scratch (O(n) complexity). With markdown parsing, this becomes prohibitively expensive.

#### 5.1 Current (Non-Incremental) Flow
```
User types → needsRedraw=true → render():
  1. Clear ENTIRE screen
  2. For EACH message:
     - Re-wrap text
     - Re-add to displayLines
  3. Draw visible portion
```

#### 5.2 Target Incremental Flow
```
Message arrives → Parse markdown once → Cache rendered lines → Mark dirty regions

On render():
  1. Only clear dirty regions (or use double-buffer diff)
  2. Only re-render changed messages
  3. Scroll changes → shift existing buffer, render new lines only
```

#### 5.3 Implementation: Cached Rendering

```nim
type
  RenderedLine* = object
    text*: string
    fgColor*: uint32
    bgColor*: uint32
    style*: uint16
    indent*: int
  
  CachedMessage* = object
    rawContent*: string
    parsedContent*: ParsedMessage
    renderedLines*: seq[RenderedLine]  # Pre-rendered lines
    height*: int                       # Total lines occupied
    dirty*: bool                       # Needs re-render
    visibleRange*: tuple[start, stop: int]  # Which lines currently visible

type
  TuiApp* = ref object
    # ... existing fields ...
    cachedMessages*: seq[CachedMessage]  # NEW: Cache for all messages
    displayBuffer*: seq[RenderedLine]    # NEW: Final display buffer
    totalContentHeight*: int             # NEW: For scrollbar/scrolling math
```

#### 5.4 Smart Invalidation

```nim
proc markMessageDirty*(app: TuiApp, msgIdx: int) =
  ## Mark specific message as needing re-render
  if msgIdx < app.cachedMessages.len:
    app.cachedMessages[msgIdx].dirty = true

proc updateCachedMessage*(app: TuiApp, msgIdx: int) =
  ## Re-parse and re-render a single message (not all!)
  var cached = app.cachedMessages[msgIdx]
  if not cached.dirty: return
  
  # Parse markdown once
  if cached.parsedContent.elements.len == 0:
    cached.parsedContent = parseMarkdown(cached.rawContent)
  
  # Render to line cache
  cached.renderedLines = @[]
  for elem in cached.parsedContent.elements:
    let lines = renderElementToLines(elem, app.chatWidth())
    cached.renderedLines.add(lines)
  
  cached.height = cached.renderedLines.len
  cached.dirty = false

proc incrementalRender*(app: TuiApp) =
  ## Only update what changed
  for i, cached in app.cachedMessages:
    if cached.dirty:
      app.updateCachedMessage(i)
      app.rebuildDisplayBuffer()  # Only rebuild if content changed
      break
```

#### 5.5 Lazy Markdown Parsing

```nim
proc getParsedContent*(cached: var CachedMessage): ParsedMessage =
  ## Parse markdown only once, on first access
  if cached.parsedContent.elements.len == 0:
    cached.parsedContent = parseMarkdown(cached.rawContent)
  return cached.parsedContent
```

#### 5.6 Viewport-Aware Rendering

```nim
proc renderChatIncremental*(app: TuiApp) =
  ## Only render lines visible in current viewport
  let viewportStart = app.scrollOffset
  let viewportEnd = viewportStart + app.chatHeight()
  
  var currentLine = 0
  for cached in app.cachedMessages:
    let msgStart = currentLine
    let msgEnd = currentLine + cached.height
    
    # Skip messages entirely above viewport
    if msgEnd < viewportStart:
      currentLine = msgEnd
      continue
    
    # Skip messages entirely below viewport  
    if msgStart > viewportEnd:
      break
    
    # Render visible portion of this message
    let visibleStart = max(0, viewportStart - msgStart)
    let visibleEnd = min(cached.height, viewportEnd - msgStart)
    
    for i in visibleStart..<visibleEnd:
      let screenY = HeaderHeight + 1 + (msgStart + i - viewportStart)
      if screenY >= 0 and screenY < getTerminalHeight() - InputHeight:
        app.renderLine(cached.renderedLines[i], screenY)
    
    currentLine = msgEnd
```

#### 5.7 Streaming Content Handling (Integration with onUpdate)

**Current Flow (from agent/loop.nim):**
```nim
# AgentLoop.processDirect() takes onUpdate callback
proc processDirect(al: AgentLoop, content, sessionKey: string,
    onUpdate: ContentUpdateCallback = nil): Future[string] {.async.}

# runLLMIteration calls notifyUpdate() during streaming:
proc notifyUpdate(isDone: bool = false) {.raises: [].} =
  if onUpdate != nil:
    let content = formatWithThinking(accumulatedReasoning, accumulatedContent)
    onUpdate(content, accumulatedReasoning, isDone)  # ← Streaming callback
```

**TUI Integration Point (from tui/core.nim):**
```nim
proc sendMessage(app: TuiApp) {.async.} =
  # Create callback for incremental updates
  let onUpdate = proc(content: string, reasoning: string, isDone: bool) {.gcsafe.} =
    {.gcsafe.}:
      if assistantMsgIdx < app.messages.len:
        app.messages[assistantMsgIdx].content = content  # ← Updates content
        app.needsRedraw = true                           # ← Marks for redraw
  
  let response = await app.agentLoop.processDirect(userInput, "tui:default", onUpdate)
```

**Problem with Markdown + Current Approach:**
Every `onUpdate` call triggers `needsRedraw = true`, which causes:
1. Full screen clear
2. Rebuilding ALL display lines from ALL messages  
3. Re-parsing markdown for the streaming message (expensive!)
4. Full re-render

**Optimized Streaming with Markdown:**

```nim
type
  StreamingState* = object
    messageIdx*: int                    # Which message is streaming
    lastContentLen*: int                # Last content length received
    lastParseTime*: MonoTime            # Throttle parsing
    pendingContent*: string             # Buffer for batched updates
    parsedCache*: ParsedMessage         # Cached parse result
    renderedCache*: seq[RenderedLine]   # Cached rendered lines
    dirtyRegion*: tuple[y1, y2: int]    # Which screen region needs update

proc onStreamingUpdate*(app: TuiApp, content, reasoning: string, isDone: bool) =
  ## Called by agent loop's notifyUpdate() - must be FAST
  let msgIdx = app.currentStreamingMsgIdx
  
  # Throttle markdown parsing (don't parse every token!)
  let now = getMonoTime()
  let timeSinceLastParse = now - app.streaming.lastParseTime
  
  if isDone or timeSinceLastParse > initDuration(milliseconds=100):
    # Parse markdown for new content
    let newParsed = parseMarkdown(content)
    app.streaming.parsedCache = newParsed
    app.streaming.lastParseTime = now
    
    # Only re-render the delta, not full message
    let deltaLines = renderNewElements(newParsed, app.streaming.lastContentLen)
    app.streaming.renderedCache.add(deltaLines)
    
    # Calculate dirty region (only where new content appears)
    let oldHeight = app.streaming.renderedCache.len - deltaLines.len
    app.streaming.dirtyRegion = (oldHeight, app.streaming.renderedCache.len)
  else:
    # Just buffer the content, wait for next throttle window
    app.streaming.pendingContent = content
  
  app.streaming.lastContentLen = content.len
  app.needsPartialRedraw = true  # ← Not full redraw!

proc renderPartial*(app: TuiApp) =
  ## Only redraw the dirty region (streaming content)
  if not app.needsPartialRedraw: return
  
  let (dirtyY1, dirtyY2) = app.streaming.dirtyRegion
  let screenStartY = HeaderHeight + 1 + dirtyY1 - app.scrollOffset
  
  # Clear only dirty region
  removeArea(0, screenStartY, app.chatWidth(), dirtyY2 - dirtyY1)
  
  # Render only new lines
  for i in dirtyY1..<dirtyY2:
    if i < app.streaming.renderedCache.len:
      let line = app.streaming.renderedCache[i]
      let screenY = screenStartY + (i - dirtyY1)
      app.renderLine(line, screenY)
  
  app.needsPartialRedraw = false
```

**Throttle Strategy:**
```nim
const
  ParseThrottleMs = 100  # Parse markdown max 10 times/second
  MinContentDelta = 20   # Minimum new chars before re-parse

proc shouldReparse*(app: TuiApp, newContent: string): bool =
  let timeOk = (getMonoTime() - app.streaming.lastParseTime).inMilliseconds > ParseThrottleMs
  let sizeOk = newContent.len - app.streaming.lastContentLen > MinContentDelta
  return timeOk or sizeOk
```

**Key Optimizations for Streaming:**

| Optimization | Before | After |
|--------------|--------|-------|
| Markdown parsing | Every token | Every 100ms or 20 chars |
| Screen clear | Full screen | Dirty region only |
| Render | All messages | Streaming message only |
| Line calculation | Re-wrap all | Append new lines only |

**Visual Example:**

```
Frame N: "Here is the code:"
  → Parse: [Text("Here is the code:")]
  → Render: 1 line
  → Draw: line at Y=10

Frame N+1 (100ms later): "Here is the code:\n\n```nim\nproc"
  → Parse: [Text("Here is the code:"), CodeBlock("proc", "nim")]
  → Render: 1 + 3 lines (code block starts)
  → Draw: only new lines at Y=11,12,13

Frame N+2 (100ms later): "...\nproc hello():\n  e..."
  → Append to existing CodeBlock, no full re-parse
  → Render: append 1 new line
  → Draw: only new line at Y=14
```

#### 5.8 Performance Budgets

| Operation | Current | Target (Incremental) |
|-----------|---------|---------------------|
| Typing character | O(n) | O(1) |
| New message | O(n) | O(1) amortized |
| Scroll up/down | O(n) | O(viewport_height) |
| Markdown parse | Every render | Once per message |
| Memory per message | O(content) | O(content + rendered_lines) |

#### 5.9 Memory Management

```nim
proc pruneOldCaches*(app: TuiApp, keepLast: int = 50) =
  ## Keep only recent messages fully rendered
  ## Older messages store just raw content, re-parse on scroll-to
  if app.cachedMessages.len > keepLast:
    for i in 0..<(app.cachedMessages.len - keepLast):
      # Keep raw content, drop rendered cache
      app.cachedMessages[i].renderedLines = @[]
      app.cachedMessages[i].parsedContent.elements = @[]
```

### Phase 6: Double Buffering (Optional Advanced)

For even smoother rendering, implement true double buffering:

```nim
type
  TerminalBuffer = object
    cells*: seq[seq[Cell]]  # 2D grid of cells
    width*, height*: int
  
  Cell = object
    char*: Rune
    fg*, bg*: uint32
    style*: uint16
    dirty*: bool

proc diffAndRender*(front, back: TerminalBuffer): seq[DiffOp] =
  ## Compare front (displayed) vs back (new), generate minimal update ops
  ## Only write changed cells to terminal
```

## Implementation Timeline

| Phase | Task | Estimated Time | Priority |
|-------|------|----------------|----------|
| 1 | Add markdown dependency | 10 min | P0 |
| 1 | Create parser module | 2 hrs | P0 |
| 2 | Create renderer module (basic) | 3 hrs | P0 |
| 2 | Syntax highlighting | 2 hrs | P1 |
| 3 | Integrate with TUI core | 3 hrs | P0 |
| 3 | Test with real LLM responses | 2 hrs | P0 |
| 4 | Expandable code blocks | 2 hrs | P2 |
| 4 | Copy to clipboard | 1 hr | P2 |
| 5 | **Incremental rendering architecture** | **4 hrs** | **P0** |
| 5 | Lazy markdown parsing | 1 hr | P0 |
| 5 | Viewport-aware rendering | 2 hrs | P0 |
| 6 | Memory management (pruning) | 1 hr | P2 |
| - | Documentation & cleanup | 1 hr | P1 |

**Total: ~24 hours of development time**

### Critical Path (P0 Features)
1. **onUpdate integration** - Streaming callback must be efficient with markdown
2. **Incremental rendering** - Must have before markdown, or TUI will be unusably slow
3. **Lazy parsing** - Parse markdown once, not every frame
4. **Basic markdown rendering** - Code blocks, headings, lists
5. **Viewport culling** - Only render what's visible

### Why onUpdate Integration is Critical

The `processDirect()` → `runLLMIteration()` → `notifyUpdate()` → `onUpdate()` chain is how streaming works:

```
Agent Loop                    TUI
    │                         │
    ├─ runLLMIteration() ─────┤
    │  ├─ streaming chunk     │
    │  ├─ notifyUpdate() ─────┼─► onUpdate(content, reasoning, isDone)
    │  │                      │    ├─ parseMarkdown(content) ⚠️ EXPENSIVE
    │  ├─ streaming chunk     │    ├─ cache rendered lines
    │  ├─ notifyUpdate() ─────┼─► onUpdate(content, reasoning, isDone)
    │  │                      │    ├─ parseMarkdown(content) ⚠️ AGAIN!
    │  └─ ...                 │    └─ ...
    │                         │
```

**Problem**: Currently `onUpdate` just sets `needsRedraw = true`, causing full re-render.

**With markdown**: Each call would re-parse the entire content → **UI freeze**

### Required Architecture Changes

**New TUI Core Types:**
```nim
type
  TuiApp* = ref object
    # ... existing fields ...
    
    # NEW: Incremental rendering state
    messageCache*: seq[CachedMessage]    # Cached render state per message
    streaming*: StreamingState           # Current streaming state
    renderMode*: RenderMode              # Full vs Partial
    
    # CHANGED: Redraw flags
    needsFullRedraw*: bool               # Rare: resize, new message
    needsPartialRedraw*: bool            # Common: streaming update

type
  RenderMode* = enum
    rmFull,       # Render everything (resize, scroll jump)
    rmPartial,    # Render only dirty region (streaming)
    rmScroll      # Shift buffer, render new viewport area
```

**Integration Point:**
```nim
# In sendMessage() - integrate with existing onUpdate
let onUpdate = proc(content: string, reasoning: string, isDone: bool) {.gcsafe.} =
  {.gcsafe.}:
    if assistantMsgIdx < app.messages.len:
      # OLD: Just update string
      # app.messages[assistantMsgIdx].content = content
      # app.needsRedraw = true
      
      # NEW: Incremental update with markdown
      app.handleStreamingUpdate(assistantMsgIdx, content, reasoning, isDone)
```

### Why Incremental Rendering is P0

Without it:
- 100 messages × parsing markdown = ~100-500ms per frame
- 30 FPS target → 33ms budget per frame
- **Result**: UI freezes during scrolling/typing

With it:
- Streaming update = parse delta only = ~2-5ms
- Scrolling = shift buffer, render ~40 lines = ~2ms
- **Result**: Smooth 60 FPS

## Testing Strategy

### Unit Tests
```nim
# tests/tmarkdown_parser.nim
import nimclaw/tui/markdown_parser

suite "Markdown Parser":
  test "parses code blocks":
    let md = "```nim\necho hello\n```"
    let parsed = parseMarkdown(md)
    check parsed.elements.len == 1
    check parsed.elements[0].kind == mdCodeBlock
    check parsed.elements[0].language == "nim"
  
  test "parses headings":
    let md = "# H1\n## H2"
    let parsed = parseMarkdown(md)
    check parsed.elements[0].kind == mdHeading
    check parsed.elements[0].level == 1
```

### Integration Tests
```nim
# tests/tui/test_rendering.nim
import nimclaw/tui/renderer

test "renders complex LLM response":
  let response = """
Here's the solution:

```nim
proc greet(name: string) =
  echo "Hello, " & name & "!"
```

Steps:
1. Import the module
2. Call `greet("world")`

> Note: This requires Nim 2.0+
"""
  # Verify rendering doesn't crash and produces expected output
```

## Migration Path

1. **Backward Compatibility**: Keep plain text mode as fallback
2. **Feature Flag**: Add `--no-markdown` CLI option to disable
3. **Gradual Rollout**: Enable for assistant messages first, then system/tool

## Future Enhancements

- **Full Syntax Highlighting**: Integrate with `tree-sitter` or `highlite`
- **Markdown Editing**: WYSIWYG markdown input in TUI
- **Image Rendering**: Support for terminal image protocols (kitty, iTerm2)
- **Link Navigation**: Open URLs in browser from TUI
- **Diff View**: Show before/after for file edits

## References

- [nim-markdown Documentation](https://www.soasme.com/nim-markdown/htmldocs/markdown.html)
- [CommonMark Spec](https://spec.commonmark.org/)
- [GFM Spec](https://github.github.com/gfm/)
- [Notes on LLM Markdown Handling](./llm_markdown_response_handling.md)
