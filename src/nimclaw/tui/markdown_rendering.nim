## Markdown Rendering for Nimclaw TUI
## 
## This module provides markdown parsing and terminal rendering for LLM responses.
## It uses nim-markdown for parsing and provides terminal-friendly rendering.

import std/[strutils, re]
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
    mdTable          # | col | col |
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

# Regex patterns for markdown elements
let
  codeBlockPattern = re"```(\\w*)\\n?((?s:.*?))```"
  inlineCodePattern = re"`([^`]+)`"
  headingPattern = re"^(#{1,6})\\s+(.+)$"
  blockQuotePattern = re"^>\\s?(.+)$"
  unorderedListPattern = re"^\\s*[-*+]\\s+(.+)$"
  orderedListPattern = re"^\\s*(\\d+)\\.\\s+(.+)$"
  boldPattern = re"\\*\\*([^*]+)\\*\\*"
  italicPattern = re"\\*([^*]+)\\*"
  strikethroughPattern = re"~~([^~]+)~~"
  linkPattern = re"\\[([^\\]]+)\\]\\(([^)]+)\\)"
  imagePattern = re"!\\[([^\\]]*)\\]\\(([^)]+)\\)"
  hrPattern = re"^(---|\\*\\*\\*|___)\\s*$"

proc detectLanguageFromContent(content: string): string =
  ## Try to detect language from code content
  if content.startsWith("proc ") or content.startsWith("func ") or
     content.startsWith("import ") or content.startsWith("type "):
    return "nim"
  if content.startsWith("def ") or content.startsWith("class ") or
     content.startsWith("import "):
    return "python"
  if content.startsWith("function ") or content.startsWith("const ") or
     content.startsWith("let ") or content.startsWith("var "):
    return "javascript"
  if content.startsWith("{") and content.contains("\""):
    return "json"
  return ""

proc extractCodeBlocks*(text: string): seq[tuple[language, content: string, start, stop: int]] =
  ## Extract code blocks from markdown text
  result = @[]
  var matches: array[3, string]
  var start = 0

  while start < text.len:
    let (first, last) = findBounds(text, codeBlockPattern, matches, start)
    if first == -1:
      break

    let lang = matches[0].toLowerAscii()
    let content = matches[1]
    result.add((lang, content, first, last))
    start = last + 1

proc parseInlineElements*(text: string): seq[MdElement] =
  ## Parse inline markdown elements (bold, italic, code, links)
  result = @[]

  var pos = 0
  var currentText = ""

  template flushText() =
    if currentText.len > 0:
      result.add(MdElement(kind: mdText, content: currentText))
      currentText = ""

  while pos < text.len:
    var foundMatch = false

    # Check for inline code (highest priority)
    var matches: array[1, string]
    let (first, last) = findBounds(text, inlineCodePattern, matches, pos, pos + 20)
    if first != -1:
      flushText()
      result.add(MdElement(kind: mdInlineCode, content: matches[0]))
      pos = last + 1
      foundMatch = true

    # Check for bold
    if not foundMatch:
      var boldMatches: array[1, string]
      let (boldFirst, boldLast) = findBounds(text, boldPattern, boldMatches, pos, pos + 30)
      if boldFirst != -1:
        flushText()
        result.add(MdElement(kind: mdStrong, content: boldMatches[0]))
        pos = boldLast + 1
        foundMatch = true

    # Check for italic (but not bold)
    if not foundMatch:
      var italicMatches: array[1, string]
      let (italicFirst, italicLast) = findBounds(text, italicPattern, italicMatches, pos, pos + 30)
      if italicFirst != -1:
        flushText()
        result.add(MdElement(kind: mdEmphasis, content: italicMatches[0]))
        pos = italicLast + 1
        foundMatch = true

    # Check for links
    if not foundMatch:
      var linkMatches: array[2, string]
      let (linkFirst, linkLast) = findBounds(text, linkPattern, linkMatches, pos, pos + 100)
      if linkFirst != -1:
        flushText()
        result.add(MdElement(kind: mdLink, content: linkMatches[0], url: linkMatches[1]))
        pos = linkLast + 1
        foundMatch = true

    # Check for strikethrough
    if not foundMatch:
      var strikeMatches: array[1, string]
      let (strikeFirst, strikeLast) = findBounds(text, strikethroughPattern, strikeMatches, pos, pos + 30)
      if strikeFirst != -1:
        flushText()
        result.add(MdElement(kind: mdStrikethrough, content: strikeMatches[0]))
        pos = strikeLast + 1
        foundMatch = true

    if not foundMatch:
      currentText.add(text[pos])
      pos += 1

  flushText()

proc parseBlockElements*(text: string): seq[MdElement] =
  ## Parse block-level elements (paragraphs, lists, headings)
  result = @[]

  var lines = text.splitLines()
  var i = 0
  var currentParagraph = ""

  template flushParagraph() =
    if currentParagraph.len > 0:
      let inlineElements = parseInlineElements(currentParagraph.strip())
      # If only one text element, flatten it
      if inlineElements.len == 1 and inlineElements[0].kind == mdText:
        result.add(MdElement(kind: mdParagraph, content: inlineElements[0].content))
      else:
        result.add(MdElement(kind: mdParagraph, content: "", children: inlineElements))
      currentParagraph = ""

  while i < lines.len:
    let line = lines[i]

    # Check for horizontal rule
    var hrMatches: array[0, string]
    if line.match(hrPattern, hrMatches):
      flushParagraph()
      result.add(MdElement(kind: mdHorizontalRule))
      i += 1
      continue

    # Check for headings
    var headingMatches: array[2, string]
    if line.match(headingPattern, headingMatches):
      flushParagraph()
      let level = headingMatches[0].len
      result.add(MdElement(
        kind: mdHeading,
        level: level,
        content: headingMatches[1]
      ))
      i += 1
      continue

    # Check for blockquotes
    var quoteMatches: array[1, string]
    if line.match(blockQuotePattern, quoteMatches):
      flushParagraph()
      var quoteLines: seq[string] = @[quoteMatches[0]]
      i += 1
      # Collect consecutive quote lines
      while i < lines.len:
        var nextQuoteMatch: array[1, string]
        if lines[i].match(blockQuotePattern, nextQuoteMatch):
          quoteLines.add(nextQuoteMatch[0])
          i += 1
        else:
          break
      result.add(MdElement(
        kind: mdBlockQuote,
        content: quoteLines.join("\n")
      ))
      continue

    # Check for unordered lists
    var ulMatches: array[1, string]
    if line.match(unorderedListPattern, ulMatches):
      flushParagraph()
      var items: seq[MdElement] = @[]
      items.add(MdElement(kind: mdText, content: ulMatches[0]))
      i += 1
      # Collect consecutive list items
      while i < lines.len:
        var nextUlMatch: array[1, string]
        if lines[i].match(unorderedListPattern, nextUlMatch):
          items.add(MdElement(kind: mdText, content: nextUlMatch[0]))
          i += 1
        else:
          break
      result.add(MdElement(kind: mdList, children: items))
      continue

    # Check for ordered lists
    var olMatches: array[2, string]
    if line.match(orderedListPattern, olMatches):
      flushParagraph()
      var items: seq[MdElement] = @[]
      items.add(MdElement(kind: mdText, content: olMatches[1]))
      i += 1
      # Collect consecutive list items
      while i < lines.len:
        var nextOlMatch: array[2, string]
        if lines[i].match(orderedListPattern, nextOlMatch):
          items.add(MdElement(kind: mdText, content: nextOlMatch[1]))
          i += 1
        else:
          break
      result.add(MdElement(kind: mdOrderedList, children: items))
      continue

    # Empty line ends paragraph
    if line.strip().len == 0:
      flushParagraph()
      i += 1
      continue

    # Regular paragraph line
    if currentParagraph.len > 0:
      currentParagraph.add(" ")
    currentParagraph.add(line)
    i += 1

  flushParagraph()

proc parseMarkdown*(text: string): ParsedMarkdown =
  ## Parse markdown text into structured elements
  result.rawText = text
  result.elements = @[]

  if text.len == 0:
    return

  # First, extract code blocks (they need special handling)
  let codeBlocks = extractCodeBlocks(text)
  var lastPos = 0

  for cb in codeBlocks:
    # Parse text before code block
    if cb.start > lastPos:
      let beforeText = text[lastPos..<cb.start]
      let beforeElements = parseBlockElements(beforeText)
      result.elements.add(beforeElements)

    # Add code block
    let lang = if cb.language.len > 0: cb.language else: detectLanguageFromContent(cb.content)
    result.elements.add(MdElement(
      kind: mdCodeBlock,
      content: cb.content,
      language: lang
    ))

    lastPos = cb.stop + 1

  # Parse remaining text after last code block
  if lastPos < text.len:
    let afterText = text[lastPos..^1]
    let afterElements = parseBlockElements(afterText)
    result.elements.add(afterElements)

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
  QuotePrefix* = "▌ "
  ListBullet* = "• "
  ListNumberWidth* = 4

proc renderToTerminalLines*(parsed: ParsedMarkdown, maxWidth: int, baseIndent: int = 0): seq[tuple[text: string, fg,
    bg: uint32, style: uint16, indent: int]] =
  ## Render parsed markdown to terminal display lines
  result = @[]

  for elem in parsed.elements:
    case elem.kind
    of mdParagraph:
      if elem.children.len > 0:
        # Render inline elements
        var lineText = ""
        for child in elem.children:
          case child.kind
          of mdText:
            lineText.add(child.content)
          of mdStrong:
            lineText.add(child.content) # Bold styling applied later
          of mdEmphasis:
            lineText.add(child.content) # Italic styling applied later
          of mdInlineCode:
            lineText.add(child.content)
          of mdLink:
            lineText.add(child.content & " (" & child.url & ")")
          of mdStrikethrough:
            lineText.add(child.content)
          else:
            lineText.add(child.content)

        # Word wrap the paragraph
        var currentLine = ""
        for word in lineText.split(' '):
          if currentLine.len == 0:
            currentLine = word
          elif currentLine.len + 1 + word.len <= maxWidth - baseIndent:
            currentLine.add(" " & word)
          else:
            result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
            currentLine = word

        if currentLine.len > 0:
          result.add((currentLine, FG_COLOR_DEFAULT, BG_COLOR_DEFAULT, STYLE_NONE, baseIndent))
      else:
        # Simple paragraph
        var currentLine = ""
        for word in elem.content.split(' '):
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
