## Markdown Rendering for Nimclaw TUI
## 
## This module provides markdown parsing and terminal rendering for LLM responses.
## Uses simple string parsing (no regex) for speed and compatibility.

import std/strutils
import textalot

type
  MdElementKind* = enum
    mdText           # Plain text
    mdHeading        # # ## ###
    mdCodeBlock      # ```lang ... ```
    mdInlineCode     # `code`
    mdList           # - item
    mdOrderedList    # 1. item
    mdBlockQuote     # > quote
    mdEmphasis       # *emphasis*
    mdStrong         # **strong**
    mdStrikethrough  # ~~strike~~
    mdLink           # [text](url)
    mdImage          # ![alt](url)
    mdHorizontalRule # ---
    mdLineBreak      # <br> or two spaces
    mdParagraph      # Paragraph block

  MdElement* = object
    kind*: MdElementKind
    content*: string
    language*: string         # For code blocks
    level*: int               # For headings (1-6)
    url*: string              # For links/images
    alt*: string              # For images
    children*: seq[MdElement] # For nested structures (lists, etc.)

  ParsedMarkdown* = object
    elements*: seq[MdElement]
    rawText*: string

proc detectLanguageFromContent(content: string): string =
  ## Try to detect language from code content
  let trimmed = content.strip()
  if trimmed.len == 0:
    return ""
  if trimmed.startsWith("proc ") or trimmed.startsWith("func ") or
     trimmed.startsWith("import ") or trimmed.startsWith("type ") or
     trimmed.startsWith("var ") or trimmed.startsWith("let ") or
     trimmed.startsWith("const ") or trimmed.startsWith("echo "):
    return "nim"
  if trimmed.startsWith("def ") or trimmed.startsWith("class ") or
     trimmed.startsWith("import ") or trimmed.startsWith("print("):
    return "python"
  if trimmed.startsWith("function ") or trimmed.startsWith("const ") or
     trimmed.startsWith("let ") or trimmed.startsWith("var ") or
     trimmed.startsWith("console.log"):
    return "javascript"
  if trimmed.startsWith("{") and trimmed.contains("\""):
    return "json"
  if trimmed.startsWith("<") and trimmed.contains(">"):
    return "html"
  return ""

proc extractCodeBlock(text: string, start: int): tuple[language, content: string, nextPos: int] =
  ## Extract a code block starting at position start
  ## Returns (language, content, position after block)
  result.language = ""
  result.content = ""
  result.nextPos = start

  if start + 3 > text.len:
    return

  # Check for opening ```
  if text[start..<start+3] != "```":
    return

  # Find language identifier (on same line as opening ```)
  var pos = start + 3
  var langEnd = pos
  while langEnd < text.len and text[langEnd] notin {'\n', '\r'}:
    langEnd.inc
  result.language = text[pos..<langEnd].strip().toLowerAscii()

  # Skip to after opening fence
  pos = langEnd
  if pos < text.len and text[pos] == '\r': pos.inc
  if pos < text.len and text[pos] == '\n': pos.inc

  # Find closing ```
  let contentStart = pos
  while pos < text.len - 2:
    if text[pos..<pos+3] == "```":
      # Found closing fence
      result.content = text[contentStart..<pos]
      result.nextPos = pos + 3
      # Auto-detect language if not specified
      if result.language.len == 0:
        result.language = detectLanguageFromContent(result.content)
      return
    pos.inc

  # No closing fence found - treat rest as code
  result.content = text[contentStart..^1]
  result.nextPos = text.len
  if result.language.len == 0:
    result.language = detectLanguageFromContent(result.content)

proc parseInlineElements(text: string): seq[MdElement] =
  ## Parse inline markdown elements (bold, italic, code, links)
  result = @[]

  var pos = 0
  var currentText = ""

  template flushText() =
    if currentText.len > 0:
      result.add(MdElement(kind: mdText, content: currentText))
      currentText = ""

  while pos < text.len:
    # Check for inline code `...`
    if pos < text.len and text[pos] == '`':
      let codeStart = pos + 1
      var codeEnd = codeStart
      while codeEnd < text.len and text[codeEnd] != '`':
        codeEnd.inc
      if codeEnd < text.len:
        flushText()
        result.add(MdElement(kind: mdInlineCode, content: text[codeStart..<codeEnd]))
        pos = codeEnd + 1
        continue

    # Check for bold **...**
    if pos + 1 < text.len and text[pos..<pos+2] == "**":
      let contentStart = pos + 2
      var contentEnd = contentStart
      while contentEnd + 1 < text.len and text[contentEnd..<contentEnd+2] != "**":
        contentEnd.inc
      if contentEnd + 1 < text.len:
        flushText()
        result.add(MdElement(kind: mdStrong, content: text[contentStart..<contentEnd]))
        pos = contentEnd + 2
        continue

    # Check for italic *...* (but not **)
    if pos < text.len and text[pos] == '*' and (pos + 1 >= text.len or text[pos+1] != '*'):
      let contentStart = pos + 1
      var contentEnd = contentStart
      while contentEnd < text.len and text[contentEnd] != '*':
        contentEnd.inc
      if contentEnd < text.len:
        flushText()
        result.add(MdElement(kind: mdEmphasis, content: text[contentStart..<contentEnd]))
        pos = contentEnd + 1
        continue

    # Check for strikethrough ~~...~~
    if pos + 1 < text.len and text[pos..<pos+2] == "~~":
      let contentStart = pos + 2
      var contentEnd = contentStart
      while contentEnd + 1 < text.len and text[contentEnd..<contentEnd+2] != "~~":
        contentEnd.inc
      if contentEnd + 1 < text.len:
        flushText()
        result.add(MdElement(kind: mdStrikethrough, content: text[contentStart..<contentEnd]))
        pos = contentEnd + 2
        continue

    # Check for links [text](url)
    if pos < text.len and text[pos] == '[':
      var textEnd = pos + 1
      while textEnd < text.len and text[textEnd] != ']':
        textEnd.inc
      if textEnd + 1 < text.len and text[textEnd + 1] == '(':
        var urlEnd = textEnd + 2
        while urlEnd < text.len and text[urlEnd] != ')':
          urlEnd.inc
        if urlEnd < text.len:
          flushText()
          result.add(MdElement(kind: mdLink,
            content: text[pos+1..<textEnd],
            url: text[textEnd+2..<urlEnd]))
          pos = urlEnd + 1
          continue

    # Regular character
    currentText.add(text[pos])
    pos.inc

  flushText()

proc isHeadingLine(line: string): tuple[isHeading: bool, level: int, content: string] =
  ## Check if a line is a markdown heading
  result.isHeading = false
  result.level = 0
  result.content = ""

  var pos = 0
  while pos < line.len and line[pos] == '#' and pos < 6:
    pos.inc

  if pos > 0 and pos < line.len and line[pos] == ' ':
    result.isHeading = true
    result.level = pos
    result.content = line[pos+1..^1].strip()

proc stripLeadingSpaces(s: string): string =
  ## Strip leading whitespace from a string
  var pos = 0
  while pos < s.len and s[pos] in {' ', '\t'}:
    pos.inc
  result = s[pos..^1]

proc isUnorderedListItem(line: string): tuple[isItem: bool, content: string] =
  ## Check if line is an unordered list item (-, *, +)
  result.isItem = false
  result.content = ""

  let stripped = line.stripLeadingSpaces()
  if stripped.len >= 2 and stripped[0] in {'-', '*', '+'} and stripped[1] == ' ':
    result.isItem = true
    result.content = stripped[2..^1].strip()

proc isOrderedListItem(line: string): tuple[isItem: bool, num: int, content: string] =
  ## Check if line is an ordered list item (1., 2., etc)
  result.isItem = false
  result.num = 0
  result.content = ""

  let stripped = line.stripLeadingSpaces()
  var pos = 0
  var num = 0
  while pos < stripped.len and stripped[pos] in {'0'..'9'}:
    num = num * 10 + (stripped[pos].ord - '0'.ord)
    pos.inc

  if pos > 0 and pos + 1 < stripped.len and stripped[pos] == '.' and stripped[pos+1] == ' ':
    result.isItem = true
    result.num = num
    result.content = stripped[pos+2..^1].strip()

proc isBlockQuote(line: string): tuple[isQuote: bool, content: string] =
  ## Check if line is a blockquote
  result.isQuote = false
  result.content = ""

  let stripped = line.stripLeadingSpaces()
  if stripped.len > 2 and stripped[0] == '>' and stripped[1] == ' ':
    result.isQuote = true
    result.content = stripped[2..^1]
  elif stripped.len == 1 and stripped[0] == '>':
    result.isQuote = true
    result.content = ""

proc isHorizontalRule(line: string): bool =
  ## Check if line is a horizontal rule (---, ***, ___)
  let stripped = line.strip()
  if stripped.len >= 3:
    if stripped[0] == '-' and stripped.count('-') == stripped.len:
      return true
    if stripped[0] == '*' and stripped.count('*') == stripped.len:
      return true
    if stripped[0] == '_' and stripped.count('_') == stripped.len:
      return true
  return false

proc parseMarkdown*(text: string): ParsedMarkdown =
  ## Parse markdown text into structured elements
  result.rawText = text
  result.elements = @[]

  if text.len == 0:
    return

  var pos = 0

  while pos < text.len:
    # Skip leading whitespace on new block
    while pos < text.len and text[pos] in {' ', '\t'}:
      pos.inc

    if pos >= text.len:
      break

    # Check for code block
    if pos + 2 < text.len and text[pos..<pos+3] == "```":
      let (lang, content, nextPos) = extractCodeBlock(text, pos)
      if nextPos > pos:
        result.elements.add(MdElement(
          kind: mdCodeBlock,
          content: content,
          language: lang
        ))
        pos = nextPos
        continue

    # Find end of current line
    var lineEnd = pos
    while lineEnd < text.len and text[lineEnd] notin {'\n', '\r'}:
      lineEnd.inc

    let line = text[pos..<lineEnd]

    # Skip empty lines
    if line.strip().len == 0:
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc
      continue

    # Check for horizontal rule
    if isHorizontalRule(line):
      result.elements.add(MdElement(kind: mdHorizontalRule))
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc
      continue

    # Check for heading
    let (isHeading, level, headingContent) = isHeadingLine(line)
    if isHeading:
      result.elements.add(MdElement(
        kind: mdHeading,
        level: level,
        content: headingContent
      ))
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc
      continue

    # Check for blockquote
    let (isQuote, quoteStart) = isBlockQuote(line)
    if isQuote:
      var quoteLines: seq[string] = @[quoteStart]
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc

      # Collect consecutive quote lines
      while pos < text.len:
        var nextLineEnd = pos
        while nextLineEnd < text.len and text[nextLineEnd] notin {'\n', '\r'}:
          nextLineEnd.inc
        let nextLine = text[pos..<nextLineEnd]

        if nextLine.strip().len == 0:
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
          continue

        let (nextIsQuote, nextQuoteContent) = isBlockQuote(nextLine)
        if nextIsQuote:
          quoteLines.add(nextQuoteContent)
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
        else:
          break

      result.elements.add(MdElement(
        kind: mdBlockQuote,
        content: quoteLines.join("\n")
      ))
      continue

    # Check for unordered list
    let (isUl, ulContent) = isUnorderedListItem(line)
    if isUl:
      var items: seq[MdElement] = @[MdElement(kind: mdText, content: ulContent)]
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc

      # Collect consecutive list items
      while pos < text.len:
        var nextLineEnd = pos
        while nextLineEnd < text.len and text[nextLineEnd] notin {'\n', '\r'}:
          nextLineEnd.inc
        let nextLine = text[pos..<nextLineEnd]

        if nextLine.strip().len == 0:
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
          continue

        let (nextIsUl, nextUlContent) = isUnorderedListItem(nextLine)
        if nextIsUl:
          items.add(MdElement(kind: mdText, content: nextUlContent))
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
        else:
          break

      result.elements.add(MdElement(kind: mdList, children: items))
      continue

    # Check for ordered list
    let (isOl, olNum, olContent) = isOrderedListItem(line)
    if isOl:
      var items: seq[MdElement] = @[MdElement(kind: mdText, content: olContent)]
      pos = lineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc

      # Collect consecutive list items
      while pos < text.len:
        var nextLineEnd = pos
        while nextLineEnd < text.len and text[nextLineEnd] notin {'\n', '\r'}:
          nextLineEnd.inc
        let nextLine = text[pos..<nextLineEnd]

        if nextLine.strip().len == 0:
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
          continue

        let (nextIsOl, _, nextOlContent) = isOrderedListItem(nextLine)
        if nextIsOl:
          items.add(MdElement(kind: mdText, content: nextOlContent))
          pos = nextLineEnd
          if pos < text.len and text[pos] == '\r': pos.inc
          if pos < text.len and text[pos] == '\n': pos.inc
        else:
          break

      result.elements.add(MdElement(kind: mdOrderedList, children: items))
      continue

    # Regular paragraph - collect lines until empty line or block element
    var paraLines: seq[string] = @[line]
    pos = lineEnd
    if pos < text.len and text[pos] == '\r': pos.inc
    if pos < text.len and text[pos] == '\n': pos.inc

    while pos < text.len:
      var nextLineEnd = pos
      while nextLineEnd < text.len and text[nextLineEnd] notin {'\n', '\r'}:
        nextLineEnd.inc
      let nextLine = text[pos..<nextLineEnd]

      # Stop at empty line or block element
      if nextLine.strip().len == 0:
        pos = nextLineEnd
        if pos < text.len and text[pos] == '\r': pos.inc
        if pos < text.len and text[pos] == '\n': pos.inc
        break

      # Check if it's a block element start
      if isHeadingLine(nextLine).isHeading or
         isUnorderedListItem(nextLine).isItem or
         isOrderedListItem(nextLine).isItem or
         isBlockQuote(nextLine).isQuote or
         isHorizontalRule(nextLine) or
         (pos + 2 < text.len and text[pos..<pos+3] == "```"):
        break

      paraLines.add(nextLine)
      pos = nextLineEnd
      if pos < text.len and text[pos] == '\r': pos.inc
      if pos < text.len and text[pos] == '\n': pos.inc

    # Parse inline elements in paragraph
    let paraText = paraLines.join(" ").strip()
    let inlineElements = parseInlineElements(paraText)

    if inlineElements.len == 1 and inlineElements[0].kind == mdText:
      result.elements.add(MdElement(kind: mdParagraph, content: inlineElements[0].content))
    else:
      result.elements.add(MdElement(kind: mdParagraph, content: "", children: inlineElements))

# Terminal rendering constants
const
  HeadingColors*: array[1..6, uint32] = [
    0xFFFFFF'u32,             # H1 - White
    0xDDDDDD'u32,             # H2 - Light gray
    0x00AAFF'u32,             # H3 - Light blue
    0x00FFAA'u32,             # H4 - Cyan/Green
    0xFFAA00'u32,             # H5 - Orange
    0xAA00FF'u32              # H6 - Purple
  ]
  CodeFg* = 0x00FF00'u32      # Green for code
  CodeBlockBg* = 0x1a1a1a'u32 # Dark background
  LinkFg* = 0x0088FF'u32      # Blue for links
  QuoteFg* = 0xFFAA00'u32     # Yellow for quotes
  ThinkingFg* = 0x888888'u32  # Grey for thinking section
  QuotePrefix* = "▌ "
  ListBullet* = "• "
  ListNumberWidth* = 4

type
  StyledSegment = object
    text: string
    style: uint16
    fg: uint32

proc wrapStyledSegments(segments: seq[StyledSegment], maxWidth, baseIndent: int): seq[tuple[text: string, fg,
    bg: uint32, style: uint16, indent: int]] =
  ## Word wrap styled segments while preserving styles
  result = @[]

  var currentLine = ""
  var currentStyle = STYLE_NONE

  for segment in segments:
    let words = segment.text.split(' ')
    for word in words:
      if word.len == 0:
        continue

      # Check if we need to start a new line
      if currentLine.len > 0 and currentLine.len + 1 + word.len > maxWidth - baseIndent:
        # Flush current line with its style
        result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, currentStyle, baseIndent))
        currentLine = ""

      # Add word to current line
      if currentLine.len == 0:
        currentLine = word
        currentStyle = segment.style
      else:
        currentLine.add(" " & word)

  # Flush remaining line
  if currentLine.len > 0:
    result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, currentStyle, baseIndent))

proc renderToTerminalLines*(parsed: ParsedMarkdown, maxWidth: int, baseIndent: int = 0): seq[tuple[text: string, fg,
    bg: uint32, style: uint16, indent: int]] =
  ## Render parsed markdown to terminal display lines
  result = @[]

  for elem in parsed.elements:
    case elem.kind
    of mdParagraph:
      if elem.children.len > 0:
        # Convert inline elements to styled segments
        var segments: seq[StyledSegment] = @[]
        for child in elem.children:
          case child.kind
          of mdText:
            segments.add(StyledSegment(text: child.content, style: STYLE_NONE, fg: FG_COLOR_DEFAULT))
          of mdStrong:
            segments.add(StyledSegment(text: child.content, style: STYLE_BOLD, fg: FG_COLOR_DEFAULT))
          of mdEmphasis:
            segments.add(StyledSegment(text: child.content, style: STYLE_ITALIC, fg: FG_COLOR_DEFAULT))
          of mdInlineCode:
            segments.add(StyledSegment(text: child.content, style: STYLE_NONE, fg: CodeFg))
          of mdLink:
            segments.add(StyledSegment(text: child.content & " (" & child.url & ")", style: STYLE_NONE, fg: LinkFg))
          of mdStrikethrough:
            segments.add(StyledSegment(text: child.content, style: STYLE_FAINT, fg: FG_COLOR_DEFAULT))
          else:
            segments.add(StyledSegment(text: child.content, style: STYLE_NONE, fg: FG_COLOR_DEFAULT))

        # Word wrap with style preservation
        let wrapped = wrapStyledSegments(segments, maxWidth, baseIndent)
        result.add(wrapped)
      else:
        # Simple paragraph without inline elements
        var currentLine = ""
        for word in elem.content.split(' '):
          if word.len == 0:
            continue
          if currentLine.len == 0:
            currentLine = word
          elif currentLine.len + 1 + word.len <= maxWidth - baseIndent:
            currentLine.add(" " & word)
          else:
            result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
            currentLine = word

        if currentLine.len > 0:
          result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

      # Empty line after paragraph
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdHeading:
      let prefix = "#".repeat(elem.level) & " "
      let headingText = prefix & elem.content
      let color = if elem.level >= 1 and elem.level <= 6:
                    HeadingColors[elem.level]
                  else:
                    FG_COLOR_DEFAULT
      result.add((headingText, color, BG_COLOR_DEFAULT, STYLE_BOLD, baseIndent))
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdCodeBlock:
      # Code block header
      let langLabel = if elem.language.len > 0: "┌─ " & elem.language & " " else: "┌─ code "
      result.add((langLabel, FG_COLOR_BLACK_BRIGHT, CodeBlockBg, STYLE_NONE, baseIndent))

      # Code content
      let codeLines = elem.content.splitLines()
      for line in codeLines:
        # Truncate if too long
        let displayLine = if line.len > maxWidth - baseIndent - 2:
                           line[0..<(maxWidth - baseIndent - 2)]
                         else:
                           line
        result.add(("│ " & displayLine, CodeFg, CodeBlockBg, STYLE_NONE, baseIndent))

      # Code block footer
      result.add(("└", FG_COLOR_BLACK_BRIGHT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdBlockQuote:
      let quoteLines = elem.content.splitLines()
      for line in quoteLines:
        let quoted = QuotePrefix & line
        result.add((quoted, QuoteFg, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdList:
      for item in elem.children:
        let bullet = ListBullet & item.content
        result.add((bullet, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent + 2))
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdOrderedList:
      var num = 1
      for item in elem.children:
        let bullet = $num & ". " & item.content
        result.add((bullet, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent + 2))
        num += 1
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    of mdHorizontalRule:
      let rule = "─".repeat(maxWidth - baseIndent)
      result.add((rule, FG_COLOR_BLACK_BRIGHT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
      result.add(("", FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))

    else:
      # Fallback for other elements
      if elem.content.len > 0:
        result.add((elem.content, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
