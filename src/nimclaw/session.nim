import std/[os, times, locks, tables, strutils, options, json, sequtils]
import pkg/regex except re
import providers/types as providers_types
import ./security
import ./logger

type
  # Legacy types for backward compatibility
  StoredMessage* = object
    role*: string
    content*: string
    name*: string
    tool_calls*: seq[StoredToolCall]
    tool_call_id*: string

  StoredToolCall* = object
    id*: string
    `type`*: string
    name*: string
    arguments*: Table[string, JsonNode]

  # NEW: Record-based session storage (Phase 1)
  RecordKind* = enum
    rkUser = "user"
    rkAssistant = "assistant"
    rkTool = "tool"
    rkSystem = "system"
    rkSummary = "summary"

  SessionRecord* = object
    ## A single record in the session (replaces flat StoredMessage)
    kind*: RecordKind
    timestamp*: int64
    content*: string
    synthetic*: bool                 # true for summaries, injected prompts, etc.
    toolCalls*: seq[StoredToolCall]  # for assistant records
    toolCallId*: string              # for tool responses
    name*: string                    # tool name or persona name
    metadata*: Table[string, string] # extensible metadata

  Session* = ref object
    key*: string
    records*: seq[SessionRecord] # NEW: structured records
    summary*: string             # DEPRECATED: kept for migration
    created*: float64
    updated*: float64
    version*: int                # NEW: format version (1 = new jsonl)

  SessionManager* = ref object
    sessions*: Table[string, Session]
    lock*: Lock
    storage*: string
    maxSessions*: int

const
  MAX_SESSION_COUNT = 1000
  MAX_SESSION_AGE_DAYS = 30
  SESSION_KEY_PATTERN = re2"^[a-zA-Z0-9:_\-]+$"
  MAX_SESSION_KEY_LENGTH = 128
  CURRENT_SESSION_VERSION = 1

# ==============================================================================
# SessionRecord helpers
# ==============================================================================

proc toRecord*(msg: providers_types.Message, synthetic: bool = false): SessionRecord =
  ## Convert internal Message to SessionRecord
  result.kind = case msg.role:
    of mrUser: rkUser
    of mrAssistant: rkAssistant
    of mrTool: rkTool
    of mrSystem: rkSystem
  result.timestamp = getTime().toUnix()
  result.content = if msg.content.isSome: msg.content.get() else: ""
  result.synthetic = synthetic
  result.name = if msg.name.isSome: msg.name.get() else: ""
  result.toolCallId = if msg.toolCallId.isSome: msg.toolCallId.get() else: ""

  for tc in msg.toolCalls:
    var storedTc = StoredToolCall(
      id: tc.id,
      `type`: "function",
      name: tc.name,
      arguments: tc.arguments
    )
    result.toolCalls.add(storedTc)

proc toInternalMessage*(record: SessionRecord): providers_types.Message =
  ## Convert SessionRecord to internal Message
  result.role = case record.kind:
    of rkUser: mrUser
    of rkAssistant: mrAssistant
    of rkTool: mrTool
    of rkSystem: mrSystem
    of rkSummary: mrSystem # summaries become system messages

  if record.content.len > 0:
    result.content = some(record.content)
  if record.name.len > 0:
    result.name = some(record.name)
  if record.toolCallId.len > 0:
    result.toolCallId = some(record.toolCallId)

  for tc in record.toolCalls:
    var internalTc = providers_types.ToolCall(
      id: tc.id,
      name: tc.name,
      arguments: tc.arguments
    )
    result.toolCalls.add(internalTc)

# ==============================================================================
# Legacy conversion helpers (for migration)
# ==============================================================================

proc toStoredMessage*(msg: providers_types.Message): StoredMessage =
  ## Convert internal Message to storage format (legacy)
  result.role = msg.role.toString()
  result.content = if msg.content.isSome: msg.content.get() else: ""
  result.name = if msg.name.isSome: msg.name.get() else: ""
  result.tool_call_id = if msg.toolCallId.isSome: msg.toolCallId.get() else: ""

  for tc in msg.toolCalls:
    var storedTc = StoredToolCall(
      id: tc.id,
      `type`: "function",
      name: tc.name,
      arguments: tc.arguments
    )
    result.tool_calls.add(storedTc)

proc toInternalMessage*(msg: StoredMessage): providers_types.Message =
  ## Convert storage format to internal Message (legacy)
  result.role = providers_types.parseMessageRole(msg.role)
  if msg.content.len > 0:
    result.content = some(msg.content)
  if msg.name.len > 0:
    result.name = some(msg.name)
  if msg.tool_call_id.len > 0:
    result.toolCallId = some(msg.tool_call_id)

  for tc in msg.tool_calls:
    var internalTc = providers_types.ToolCall(
      id: tc.id,
      name: tc.name,
      arguments: tc.arguments
    )
    result.toolCalls.add(internalTc)

proc storedMessageToRecord*(sm: StoredMessage): SessionRecord =
  ## Convert legacy StoredMessage to SessionRecord
  result.kind = case sm.role:
    of "user": rkUser
    of "assistant": rkAssistant
    of "tool": rkTool
    of "system": rkSystem
    else: rkUser
  result.timestamp = getTime().toUnix()
  result.content = sm.content
  result.name = sm.name
  result.toolCallId = sm.tool_call_id
  result.toolCalls = sm.tool_calls
  result.synthetic = false

# ==============================================================================
# JSONL serialization (new format)
# ==============================================================================

proc recordToJson*(r: SessionRecord): JsonNode =
  ## Convert SessionRecord to JSON
  result = %*{
    "kind": $r.kind,
    "timestamp": r.timestamp,
    "content": r.content,
    "synthetic": r.synthetic,
    "toolCallId": r.toolCallId,
    "name": r.name,
    "metadata": r.metadata
  }

  # Add tool calls if present
  if r.toolCalls.len > 0:
    var tcArray = newJArray()
    for tc in r.toolCalls:
      tcArray.add(%*{
        "id": tc.id,
        "type": tc.`type`,
        "name": tc.name,
        "arguments": tc.arguments
      })
    result["toolCalls"] = tcArray

proc recordFromJson*(j: JsonNode): SessionRecord =
  ## Convert JSON to SessionRecord
  result.kind = parseEnum[RecordKind](j["kind"].getStr("user"))
  result.timestamp = j["timestamp"].getBiggestInt(0)
  result.content = j["content"].getStr("")
  result.synthetic = j["synthetic"].getBool(false)
  result.toolCallId = j["toolCallId"].getStr("")
  result.name = j["name"].getStr("")

  if j.hasKey("metadata") and j["metadata"].kind == JObject:
    for k, v in j["metadata"]:
      result.metadata[k] = v.getStr("")

  if j.hasKey("toolCalls") and j["toolCalls"].kind == JArray:
    for tcNode in j["toolCalls"]:
      var tc = StoredToolCall(
        id: tcNode["id"].getStr(""),
        `type`: tcNode["type"].getStr("function"),
        name: tcNode["name"].getStr(""),
        arguments: initTable[string, JsonNode]()
      )
      if tcNode.hasKey("arguments") and tcNode["arguments"].kind == JObject:
        for k, v in tcNode["arguments"]:
          tc.arguments[k] = v
      result.toolCalls.add(tc)

proc saveSessionJsonl*(sm: SessionManager, session: Session) =
  ## Save session as JSONL (new format)
  if sm.storage == "":
    return

  let filepath = sm.storage / (session.key & ".jsonl")
  var f: File
  if open(f, filepath, fmWrite):
    try:
      # Write metadata as first line comment/header
      let header = %*{
        "_meta": true,
        "key": session.key,
        "created": session.created,
        "updated": getTime().toUnixFloat(),
        "version": CURRENT_SESSION_VERSION
      }
      f.writeLine($header)

      # Write each record
      for record in session.records:
        f.writeLine($(recordToJson(record)))

      info "Saved session", key = session.key, records = session.records.len, format = "jsonl"
    finally:
      f.close()
  else:
    warn "Failed to save session", key = session.key, path = filepath

proc loadSessionJsonl*(filepath: string): Session =
  ## Load session from JSONL format
  result = Session(
    key: "",
    records: @[],
    version: CURRENT_SESSION_VERSION
  )

  for line in lines(filepath):
    if line.len == 0:
      continue

    try:
      let j = parseJson(line)

      # Check if metadata line
      if j.hasKey("_meta") and j["_meta"].getBool(false):
        result.key = j["key"].getStr("")
        result.created = j["created"].getFloat()
        result.updated = j["updated"].getFloat()
        result.version = j["version"].getInt(1)
      else:
        # Regular record
        result.records.add(recordFromJson(j))
    except CatchableError as e:
      warn "Failed to parse session line", line = line[0..min(50, line.len-1)], error = e.msg

  result.updated = getTime().toUnixFloat()

# ==============================================================================
# Legacy JSON serialization (for migration)
# ==============================================================================

proc saveSessionLegacy*(sm: SessionManager, session: Session) =
  ## Save session as legacy JSON format
  if sm.storage == "":
    return

  let filepath = sm.storage / (session.key & ".json")
  var jsonObj = %*{
    "key": session.key,
    "summary": session.summary,
    "created": session.created,
    "updated": getTime().toUnixFloat()
  }

  # Convert records to legacy format
  var msgArray = newJArray()
  for record in session.records:
    if record.kind in {rkUser, rkAssistant, rkTool, rkSystem}:
      msgArray.add(%*{
        "role": $record.kind,
        "content": record.content,
        "name": record.name,
        "tool_call_id": record.toolCallId,
        "tool_calls": record.toolCalls.mapIt(%*{
          "id": it.id,
          "type": it.`type`,
          "name": it.name,
          "arguments": it.arguments
        })
      })
  jsonObj["messages"] = msgArray

  writeFile(filepath, $jsonObj)

proc migrateLegacySession*(sm: SessionManager, filepath: string): Session =
  ## Migrate legacy JSON session to new format
  let jsonData = readFile(filepath)
  let jsonNode = parseJson(jsonData)

  var session = Session(key: "")

  if jsonNode.hasKey("key"):
    session.key = jsonNode["key"].getStr("")
  if jsonNode.hasKey("summary"):
    session.summary = jsonNode["summary"].getStr("")
  if jsonNode.hasKey("created"):
    session.created = jsonNode["created"].getFloat()
  if jsonNode.hasKey("updated"):
    session.updated = jsonNode["updated"].getFloat()

  # Convert messages to records
  if jsonNode.hasKey("messages") and jsonNode["messages"].kind == JArray:
    for msgNode in jsonNode["messages"]:
      var sm = StoredMessage()
      if msgNode.hasKey("role"):
        sm.role = msgNode["role"].getStr("")
      if msgNode.hasKey("content"):
        sm.content = msgNode["content"].getStr("")
      if msgNode.hasKey("name"):
        sm.name = msgNode["name"].getStr("")
      if msgNode.hasKey("tool_call_id"):
        sm.tool_call_id = msgNode["tool_call_id"].getStr("")
      if msgNode.hasKey("tool_calls") and msgNode["tool_calls"].kind == JArray:
        for tcNode in msgNode["tool_calls"]:
          var tc = StoredToolCall()
          if tcNode.hasKey("id"):
            tc.id = tcNode["id"].getStr("")
          if tcNode.hasKey("type"):
            tc.`type` = tcNode["type"].getStr("function")
          if tcNode.hasKey("name"):
            tc.name = tcNode["name"].getStr("")
          # Handle function wrapper
          if tcNode.hasKey("function") and tcNode["function"].kind == JObject:
            let fnNode = tcNode["function"]
            if fnNode.hasKey("name"):
              tc.name = fnNode["name"].getStr("")
            if fnNode.hasKey("arguments"):
              let argsNode = fnNode["arguments"]
              if argsNode.kind == JObject:
                for k, v in argsNode:
                  tc.arguments[k] = v
              elif argsNode.kind == JString:
                try:
                  let parsed = parseJson(argsNode.getStr(""))
                  if parsed.kind == JObject:
                    for k, v in parsed:
                      tc.arguments[k] = v
                except:
                  discard
          sm.tool_calls.add(tc)
      session.records.add(storedMessageToRecord(sm))

  session.version = CURRENT_SESSION_VERSION

  # Save in new format and remove old
  sm.saveSessionJsonl(session)
  try:
    removeFile(filepath)
    info "Migrated legacy session to JSONL", key = session.key
  except CatchableError as e:
    warn "Failed to remove legacy session file", path = filepath, error = e.msg

  return session

# ==============================================================================
# SessionManager
# ==============================================================================

proc newSessionManager*(storage: string, maxSessions: int = MAX_SESSION_COUNT): SessionManager =
  result = SessionManager(
    sessions: initTable[string, Session](),
    storage: storage,
    maxSessions: maxSessions
  )
  initLock(result.lock)

  if storage != "":
    # Sanitize storage path
    let safeStorage = sanitizePath(storage)
    if safeStorage != storage:
      raise newException(ValueError, "Invalid storage path: " & storage)
    if not dirExists(safeStorage):
      try:
        createDir(safeStorage)
      except IOError as e:
        raise newException(IOError, "Failed to create storage directory: " & e.msg)

    # Load existing sessions
    # First check for new JSONL format
    for file in walkFiles(safeStorage / "*.jsonl"):
      try:
        let filename = extractFilename(file)
        let sessionKey = filename[0..<filename.len-6] # Remove ".jsonl"

        if not isValidSessionKey(sessionKey):
          try:
            removeFile(file)
          except:
            discard
          continue

        let session = loadSessionJsonl(file)
        if session.key == sessionKey:
          result.sessions[sessionKey] = session
        else:
          warn "Session key mismatch", file = file, expected = sessionKey, got = session.key
          try:
            removeFile(file)
          except:
            discard
      except CatchableError as e:
        warn "Failed to load JSONL session", file = file, error = e.msg

    # Then migrate legacy JSON sessions
    for file in walkFiles(safeStorage / "*.json"):
      try:
        let filename = extractFilename(file)
        let sessionKey = filename[0..<filename.len-5] # Remove ".json"

        if not isValidSessionKey(sessionKey):
          try:
            removeFile(file)
          except:
            discard
          continue

        let session = result.migrateLegacySession(file)
        if session.key == sessionKey:
          result.sessions[sessionKey] = session
      except CatchableError as e:
        warn "Failed to migrate legacy session", file = file, error = e.msg

proc validateSessionKey*(key: string): bool =
  ## Validates that a session key is safe to use
  if key.len == 0 or key.len > MAX_SESSION_KEY_LENGTH:
    return false
  if not key.match(SESSION_KEY_PATTERN):
    return false
  if ".." in key or "/" in key or "\\" in key:
    return false
  return true

proc sanitizeSessionKey*(key: string): string =
  ## Sanitizes a session key by removing dangerous characters
  var sanitized = key
  sanitized = sanitized.multiReplace(("../", ""), ("..", ""), ("\\", ""), ("/", "_"), ("|", "_"), ("*", "_"), ("?", "_"))
  sanitized = sanitized.replace(re2"[^a-zA-Z0-9:_\-]", "_")
  if sanitized.len > MAX_SESSION_KEY_LENGTH:
    sanitized = sanitized[0..<MAX_SESSION_KEY_LENGTH]
  return sanitized

proc getOrCreate*(sm: SessionManager, key: string): Session =
  ## Get an existing session or create a new one with the given key
  var safeKey = key

  if not validateSessionKey(safeKey):
    safeKey = sanitizeSessionKey(safeKey)
    if not validateSessionKey(safeKey):
      raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(safeKey):
    return sm.sessions[safeKey]
  else:
    # Check max session limit
    if sm.sessions.len >= sm.maxSessions:
      var oldestKey = ""
      var oldestTime: float64 = high(float64)
      for k, s in sm.sessions:
        if s.created < oldestTime:
          oldestTime = s.created
          oldestKey = k
      if oldestKey != "":
        sm.sessions.del(oldestKey)
        if sm.storage != "":
          try:
            removeFile(sm.storage / (oldestKey & ".jsonl"))
            removeFile(sm.storage / (oldestKey & ".json")) # legacy
          except:
            discard

    let session = Session(
      key: safeKey,
      records: @[],
      created: getTime().toUnixFloat(),
      updated: getTime().toUnixFloat(),
      version: CURRENT_SESSION_VERSION
    )
    sm.sessions[safeKey] = session
    return session

proc save*(sm: SessionManager, session: Session) =
  ## Save a session to disk
  acquire(sm.lock)
  defer: release(sm.lock)

  session.updated = getTime().toUnixFloat()
  sm.sessions[session.key] = session
  sm.saveSessionJsonl(session)

proc getHistory*(sm: SessionManager, key: string): seq[providers_types.Message] =
  ## Get conversation history as messages
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return @[]

  let session = sm.sessions[key]
  for record in session.records:
    # Skip synthetic records (like summaries) when returning history
    if not record.synthetic:
      result.add(toInternalMessage(record))

proc getSummary*(sm: SessionManager, key: string): string =
  ## Get session summary (legacy)
  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(key):
    return sm.sessions[key].summary
  return ""

proc setSummary*(sm: SessionManager, key, summary: string) =
  ## Set session summary (legacy)
  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(key):
    sm.sessions[key].summary = summary

proc addMessage*(sm: SessionManager, key, role, content: string) =
  ## Add a simple message to a session
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return

  let kind = case role:
    of "user": rkUser
    of "assistant": rkAssistant
    of "tool": rkTool
    of "system": rkSystem
    else: rkUser

  let record = SessionRecord(
    kind: kind,
    timestamp: getTime().toUnix(),
    content: content,
    synthetic: false
  )

  sm.sessions[key].records.add(record)
  sm.sessions[key].updated = getTime().toUnixFloat()

proc addFullMessage*(sm: SessionManager, key: string, msg: providers_types.Message) =
  ## Add a full message to a session
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return

  let record = toRecord(msg, synthetic = false)
  sm.sessions[key].records.add(record)
  sm.sessions[key].updated = getTime().toUnixFloat()

proc addRecord*(sm: SessionManager, key: string, record: SessionRecord) =
  ## Add a record to a session
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return

  sm.sessions[key].records.add(record)
  sm.sessions[key].updated = getTime().toUnixFloat()

proc popRecord*(sm: SessionManager, key: string, n: int = 1): seq[SessionRecord] =
  ## Remove and return the last N records (for undo)
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return @[]

  var session = sm.sessions[key]
  let toRemove = min(n, session.records.len)

  if toRemove == 0:
    return @[]

  # Get the records to remove
  result = session.records[session.records.len - toRemove .. ^1]

  # Remove them
  session.records.setLen(session.records.len - toRemove)
  session.updated = getTime().toUnixFloat()

  info "Popped records", session = key, count = toRemove

proc getRecords*(sm: SessionManager, key: string): seq[SessionRecord] =
  ## Get all records for a session
  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(key):
    return sm.sessions[key].records
  return @[]

proc getRecordCount*(sm: SessionManager, key: string): int =
  ## Get the number of records in a session
  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(key):
    return sm.sessions[key].records.len
  return 0

proc clearSession*(sm: SessionManager, key: string) =
  ## Clear all records from a session (keep metadata)
  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(key):
    sm.sessions[key].records = @[]
    sm.sessions[key].updated = getTime().toUnixFloat()
    info "Cleared session", key = key

proc truncateHistory*(sm: SessionManager, key: string, keepLast: int) =
  ## Truncate history to keep only last N records (mark older as synthetic/summary)
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return

  var session = sm.sessions[key]
  if session.records.len <= keepLast:
    return

  # Mark older records as synthetic (they're now summarized)
  let keepIndex = session.records.len - keepLast
  for i in 0 ..< keepIndex:
    session.records[i].synthetic = true

  info "Truncated history", session = key, kept = keepLast, marked = keepIndex

proc addSummaryRecord*(sm: SessionManager, key, summary: string) =
  ## Add a summary record to the session
  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(key):
    return

  let record = SessionRecord(
    kind: rkSummary,
    timestamp: getTime().toUnix(),
    content: summary,
    synthetic: true
  )

  # Insert summary at the beginning of non-synthetic records
  var session = sm.sessions[key]
  var insertPos = 0
  for i in 0 ..< session.records.len:
    if not session.records[i].synthetic:
      insertPos = i
      break

  session.records.insert(record, insertPos)
  session.updated = getTime().toUnixFloat()

  info "Added summary record", session = key
