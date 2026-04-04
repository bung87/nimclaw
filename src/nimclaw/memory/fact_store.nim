## Fact Store for Long-Term Memory
##
## Stores user preferences and facts extracted from conversations.
## Simple JSONL-based implementation (Phase 3.1)

import std/[os, times, json, strutils, options, sequtils, algorithm]
import ../logger

type
  Fact* = object
    namespace*: string # "user", "project", "global"
    key*: string
    value*: string
    source*: string    # session key where fact was extracted
    confidence*: float # 0.0-1.0
    timestamp*: int64
    accessCount*: int  # for LRU eviction
    lastAccessed*: int64

  FactStore* = ref object
    path*: string
    facts*: seq[Fact]
    maxFacts*: int
    dirty*: bool

  FactStoreError* = object of CatchableError

proc newFactStore*(workspace: string, maxFacts: int = 1000): FactStore =
  ## Create new fact store
  let path = workspace / "memory" / "facts.jsonl"

  # Ensure directory exists
  let dir = parentDir(path)
  if not dirExists(dir):
    try:
      createDir(dir)
    except CatchableError as e:
      warn "Failed to create facts directory", path = dir, error = e.msg

  result = FactStore(
    path: path,
    facts: @[],
    maxFacts: maxFacts,
    dirty: false
  )

  # Load existing facts
  if fileExists(path):
    try:
      for line in lines(path):
        if line.len == 0:
          continue
        try:
          let j = parseJson(line)
          let fact = Fact(
            namespace: j["namespace"].getStr("user"),
            key: j["key"].getStr(""),
            value: j["value"].getStr(""),
            source: j["source"].getStr(""),
            confidence: j["confidence"].getFloat(1.0),
            timestamp: j["timestamp"].getBiggestInt(0),
            accessCount: j["accessCount"].getInt(0),
            lastAccessed: j["lastAccessed"].getBiggestInt(0)
          )
          if fact.key.len > 0:
            result.facts.add(fact)
        except CatchableError as e:
          warn "Failed to parse fact", line = line[0..min(50, line.len-1)], error = e.msg

      info "Loaded facts", count = result.facts.len
    except CatchableError as e:
      warn "Failed to load facts", path = path, error = e.msg

proc save*(fs: FactStore) =
  ## Save facts to disk
  if not fs.dirty:
    return

  try:
    var f: File
    if open(f, fs.path, fmWrite):
      try:
        for fact in fs.facts:
          let j = %*{
            "namespace": fact.namespace,
            "key": fact.key,
            "value": fact.value,
            "source": fact.source,
            "confidence": fact.confidence,
            "timestamp": fact.timestamp,
            "accessCount": fact.accessCount,
            "lastAccessed": fact.lastAccessed
          }
          f.writeLine($j)
      finally:
        f.close()

      fs.dirty = false
      debug "Saved facts", count = fs.facts.len
  except CatchableError as e:
    warn "Failed to save facts", path = fs.path, error = e.msg

proc put*(fs: FactStore, namespace, key, value: string, source: string = "", confidence: float = 1.0) =
  ## Store a fact
  let now = getTime().toUnix()

  # Check if fact already exists
  for i, fact in fs.facts:
    if fact.namespace == namespace and fact.key == key:
      # Update existing fact
      fs.facts[i].value = value
      fs.facts[i].confidence = confidence
      fs.facts[i].source = source
      fs.facts[i].timestamp = now
      fs.facts[i].accessCount = fact.accessCount + 1
      fs.facts[i].lastAccessed = now
      fs.dirty = true
      debug "Updated fact", namespace = namespace, key = key
      return

  # Add new fact
  let fact = Fact(
    namespace: namespace,
    key: key,
    value: value,
    source: source,
    confidence: confidence,
    timestamp: now,
    accessCount: 1,
    lastAccessed: now
  )
  fs.facts.add(fact)
  fs.dirty = true

  # Evict old facts if over limit
  if fs.facts.len > fs.maxFacts:
    # Sort by lastAccessed (oldest first)
    fs.facts.sort(proc(a, b: Fact): int =
      if a.lastAccessed < b.lastAccessed: return -1
      if a.lastAccessed > b.lastAccessed: return 1
      return 0
    )
    # Remove oldest 10%
    let toRemove = fs.maxFacts div 10
    fs.facts = fs.facts[toRemove..^1]
    info "Evicted old facts", removed = toRemove, remaining = fs.facts.len

proc get*(fs: FactStore, namespace, key: string): Option[string] =
  ## Retrieve a fact value
  let now = getTime().toUnix()

  for i, fact in fs.facts:
    if fact.namespace == namespace and fact.key == key:
      # Update access stats
      fs.facts[i].accessCount = fact.accessCount + 1
      fs.facts[i].lastAccessed = now
      fs.dirty = true
      return some(fact.value)

  return none(string)

proc has*(fs: FactStore, namespace, key: string): bool =
  ## Check if a fact exists
  for fact in fs.facts:
    if fact.namespace == namespace and fact.key == key:
      return true
  return false

proc delete*(fs: FactStore, namespace, key: string): bool =
  ## Delete a fact
  for i, fact in fs.facts:
    if fact.namespace == namespace and fact.key == key:
      fs.facts.delete(i)
      fs.dirty = true
      return true
  return false

proc search*(fs: FactStore, namespace, query: string): seq[Fact] =
  ## Search facts by namespace and key substring (case-insensitive)
  let lowerQuery = query.toLowerAscii()
  let now = getTime().toUnix()

  for i, fact in fs.facts:
    if fact.namespace == namespace:
      if fact.key.toLowerAscii().contains(lowerQuery) or
         fact.value.toLowerAscii().contains(lowerQuery):
        # Update access stats
        fs.facts[i].accessCount = fact.accessCount + 1
        fs.facts[i].lastAccessed = now
        result.add(fact)

  fs.dirty = fs.dirty or (result.len > 0)

  # Sort by confidence (highest first), then by recency
  result.sort(proc(a, b: Fact): int =
    if a.confidence > b.confidence: return -1
    if a.confidence < b.confidence: return 1
    if a.timestamp > b.timestamp: return -1
    if a.timestamp < b.timestamp: return 1
    return 0
  )

proc getAll*(fs: FactStore, namespace: string): seq[Fact] =
  ## Get all facts in a namespace
  let now = getTime().toUnix()

  for i, fact in fs.facts:
    if fact.namespace == namespace:
      fs.facts[i].lastAccessed = now
      result.add(fact)

  fs.dirty = fs.dirty or (result.len > 0)

  # Sort by confidence, then recency
  result.sort(proc(a, b: Fact): int =
    if a.confidence > b.confidence: return -1
    if a.confidence < b.confidence: return 1
    if a.timestamp > b.timestamp: return -1
    if a.timestamp < b.timestamp: return 1
    return 0
  )

proc getTopK*(fs: FactStore, namespace: string, k: int): seq[Fact] =
  ## Get top K most accessed facts in namespace
  let now = getTime().toUnix()
  var facts: seq[Fact] = @[]

  for i, fact in fs.facts:
    if fact.namespace == namespace:
      fs.facts[i].lastAccessed = now
      facts.add(fact)

  fs.dirty = fs.dirty or (facts.len > 0)

  # Sort by access count (descending)
  facts.sort(proc(a, b: Fact): int =
    if a.accessCount > b.accessCount: return -1
    if a.accessCount < b.accessCount: return 1
    return 0
  )

  # Return top K
  let limit = min(k, facts.len)
  return facts[0..<limit]

proc getRecent*(fs: FactStore, namespace: string, since: int64): seq[Fact] =
  ## Get facts added since timestamp
  let now = getTime().toUnix()

  for i, fact in fs.facts:
    if fact.namespace == namespace and fact.timestamp >= since:
      fs.facts[i].lastAccessed = now
      result.add(fact)

  fs.dirty = fs.dirty or (result.len > 0)

proc formatForContext*(facts: seq[Fact]): string =
  ## Format facts for injection into system prompt
  if facts.len == 0:
    return ""

  result = "## User Facts & Preferences\n\n"
  for fact in facts:
    result.add("- " & fact.key & ": " & fact.value & "\n")
  result.add("\n")

proc clear*(fs: FactStore, namespace: string = "") =
  ## Clear facts (all or by namespace)
  if namespace == "":
    fs.facts = @[]
  else:
    fs.facts = fs.facts.filterIt(it.namespace != namespace)
  fs.dirty = true
  info "Cleared facts", namespace = if namespace == "": "all" else: namespace

# ==============================================================================
# Fact extraction helpers
# ==============================================================================

proc parseExtractionOutput*(output: string): seq[tuple[key, value: string]] =
  ## Parse fact extraction output from LLM
  ## Expected format: "- <key>: <value>" or "* <key>: <value>"
  for line in output.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0:
      continue

    # Check for bullet point format
    if trimmed.startsWith("-") or trimmed.startsWith("*"):
      let content = trimmed[1..^1].strip()

      # Look for key: value separator
      let colonPos = content.find(":")
      if colonPos > 0:
        let key = content[0..<colonPos].strip()
        let value = content[colonPos+1..^1].strip()
        if key.len > 0 and value.len > 0:
          result.add((key, value))

proc createExtractionPrompt*(conversation: string): string =
  ## Create prompt for fact extraction
  result = """Extract explicit user preferences, facts, and context from this conversation.
Output as bullet points in the format: "- <key>: <value>"

Only extract concrete facts, not inferences or assumptions.
Examples of good extractions:
- Preferred language: Python
- Project type: Web application
- Database: PostgreSQL

Conversation:
""" & conversation & """

Extracted facts:"""
