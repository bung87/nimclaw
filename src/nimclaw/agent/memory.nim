import std/[os, times, strutils, options]
import ../memory/fact_store as fact_store
import ../logger

type
  MemoryStore* = ref object
    workspace*: string
    memoryDir*: string
    memoryFile*: string
    factStore*: fact_store.FactStore # NEW: Long-term fact storage

proc newMemoryStore*(workspace: string): MemoryStore =
  let memoryDir = workspace / "memory"
  let memoryFile = memoryDir / "MEMORY.md"
  if not dirExists(memoryDir):
    createDir(memoryDir)

  # Create fact store for long-term memory
  let facts = fact_store.newFactStore(workspace)

  MemoryStore(
    workspace: workspace,
    memoryDir: memoryDir,
    memoryFile: memoryFile,
    factStore: facts
  )

proc getTodayFile(ms: MemoryStore): string =
  let today = now().format("yyyyMMdd")
  let monthDir = today[0..5]
  return ms.memoryDir / monthDir / (today & ".md")

proc readLongTerm*(ms: MemoryStore): string =
  if fileExists(ms.memoryFile):
    return readFile(ms.memoryFile)
  return ""

proc writeLongTerm*(ms: MemoryStore, content: string) =
  writeFile(ms.memoryFile, content)

proc readToday*(ms: MemoryStore): string =
  let todayFile = ms.getTodayFile()
  if fileExists(todayFile):
    return readFile(todayFile)
  return ""

proc appendToday*(ms: MemoryStore, content: string) =
  let todayFile = ms.getTodayFile()
  let monthDir = parentDir(todayFile)
  if not dirExists(monthDir):
    createDir(monthDir)

  var existingContent = ""
  if fileExists(todayFile):
    existingContent = readFile(todayFile)

  var newContent = ""
  if existingContent == "":
    let header = "# " & now().format("yyyy-MM-dd") & "\n\n"
    newContent = header & content
  else:
    newContent = existingContent & "\n" & content

  writeFile(todayFile, newContent)

proc getRecentDailyNotes*(ms: MemoryStore, days: int): string =
  var notes: seq[string] = @[]
  for i in 0 ..< days:
    let date = now() - i.days
    let dateStr = date.format("yyyyMMdd")
    let monthDir = dateStr[0..5]
    let filePath = ms.memoryDir / monthDir / (dateStr & ".md")
    if fileExists(filePath):
      notes.add(readFile(filePath))

  if notes.len == 0: return ""
  return notes.join("\n\n---\n\n")

proc getMemoryContext*(ms: MemoryStore): string =
  var parts: seq[string] = @[]

  # Add facts (new long-term memory)
  let facts = ms.factStore.getTopK("user", 10)
  if facts.len > 0:
    parts.add(fact_store.formatForContext(facts))

  # Add legacy long-term memory
  let longTerm = ms.readLongTerm()
  if longTerm != "":
    parts.add("## Long-term Memory\n\n" & longTerm)

  let recentNotes = ms.getRecentDailyNotes(3)
  if recentNotes != "":
    parts.add("## Recent Daily Notes\n\n" & recentNotes)

  if parts.len == 0: return ""
  return "# Memory\n\n" & parts.join("\n\n---\n\n")

# ==============================================================================
# Fact Store wrappers
# ==============================================================================

proc rememberFact*(ms: MemoryStore, key, value: string, source: string = "", confidence: float = 1.0) =
  ## Store a user fact
  ms.factStore.put("user", key, value, source, confidence)
  ms.factStore.save()

proc getFact*(ms: MemoryStore, key: string): Option[string] =
  ## Retrieve a user fact
  ms.factStore.get("user", key)

proc hasFact*(ms: MemoryStore, key: string): bool =
  ## Check if a fact exists
  ms.factStore.has("user", key)

proc searchFacts*(ms: MemoryStore, query: string): seq[fact_store.Fact] =
  ## Search user facts
  ms.factStore.search("user", query)

proc forgetFact*(ms: MemoryStore, key: string): bool =
  ## Delete a user fact
  result = ms.factStore.delete("user", key)
  if result:
    ms.factStore.save()

proc extractAndStoreFacts*(ms: MemoryStore, conversation, source: string) =
  ## Extract facts from conversation and store them
  ## Note: Actual extraction should be done by LLM, this just stores pre-extracted facts
  ## The LLM should output in format: "- key: value"
  let extracted = fact_store.parseExtractionOutput(conversation)
  for (key, value) in extracted:
    ms.factStore.put("user", key, value, source, confidence = 0.9)

  if extracted.len > 0:
    ms.factStore.save()
    info "Extracted and stored facts", count = extracted.len

proc getFactsForContext*(ms: MemoryStore, maxFacts: int = 10): string =
  ## Get formatted facts for system prompt
  let facts = ms.factStore.getTopK("user", maxFacts)
  return fact_store.formatForContext(facts)
