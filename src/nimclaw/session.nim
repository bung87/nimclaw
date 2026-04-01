import std/[os, times, locks, tables, strutils, options, json]
import pkg/regex except re
import providers/types as providers_types
import ./security

type
  # Simple message struct for storage (JSON-compatible)
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

  Session* = ref object
    key*: string
    messages*: seq[StoredMessage]
    summary*: string
    created*: float64
    updated*: float64

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

# ==============================================================================
# Conversion helpers between stored and internal formats
# ==============================================================================

proc toStoredMessage*(msg: providers_types.Message): StoredMessage =
  ## Convert internal Message to storage format
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
  ## Convert storage format to internal Message
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

proc newSessionManager*(storage: string, maxSessions: int = MAX_SESSION_COUNT): SessionManager =
  result = SessionManager(
    sessions: initTable[string, Session](),
    storage: storage,
    maxSessions: maxSessions
  )
  initLock(result.lock)
  if storage != "":
    # Sanitize storage path to prevent path traversal
    let safeStorage = sanitizePath(storage)
    if safeStorage != storage:
      raise newException(ValueError, "Invalid storage path: " & storage)
    if not dirExists(safeStorage):
      try:
        createDir(safeStorage)
      except IOError as e:
        raise newException(IOError, "Failed to create storage directory: " & e.msg)
    # loadSessions would be here
    for file in walkFiles(safeStorage / "*.json"):
      try:
        # Extract session key from filename BEFORE loading JSON (TOCTOU fix)
        let filename = extractFilename(file)
        if not filename.endsWith(".json"):
          continue
        let sessionKey = filename[0..<filename.len-5] # Remove ".json"

        # Validate session key before parsing JSON (use isValidSessionKey from security)
        if not isValidSessionKey(sessionKey):
          # Remove malformed session file
          try:
            removeFile(file)
          except:
            discard
          continue

        let jsonData = readFile(file)
        let jsonNode = parseJson(jsonData)

        # Manual deserialization for compatibility
        var session = Session(key: sessionKey)
        if jsonNode.hasKey("summary"):
          session.summary = jsonNode["summary"].getStr("")
        if jsonNode.hasKey("created"):
          session.created = jsonNode["created"].getFloat()
        if jsonNode.hasKey("updated"):
          session.updated = jsonNode["updated"].getFloat()
        if jsonNode.hasKey("messages") and jsonNode["messages"].kind == JArray:
          for msgNode in jsonNode["messages"]:
            var storedMsg = StoredMessage()
            if msgNode.hasKey("role"):
              storedMsg.role = msgNode["role"].getStr("")
            if msgNode.hasKey("content"):
              storedMsg.content = msgNode["content"].getStr("")
            if msgNode.hasKey("name"):
              storedMsg.name = msgNode["name"].getStr("")
            if msgNode.hasKey("tool_call_id"):
              storedMsg.tool_call_id = msgNode["tool_call_id"].getStr("")
            if msgNode.hasKey("tool_calls") and msgNode["tool_calls"].kind == JArray:
              for tcNode in msgNode["tool_calls"]:
                var storedTc = StoredToolCall()
                if tcNode.hasKey("id"):
                  storedTc.id = tcNode["id"].getStr("")
                if tcNode.hasKey("type"):
                  storedTc.`type` = tcNode["type"].getStr("function")
                if tcNode.hasKey("name"):
                  storedTc.name = tcNode["name"].getStr("")
                # Handle function wrapper if present
                if tcNode.hasKey("function") and tcNode["function"].kind == JObject:
                  let fnNode = tcNode["function"]
                  if fnNode.hasKey("name"):
                    storedTc.name = fnNode["name"].getStr("")
                  if fnNode.hasKey("arguments"):
                    let argsNode = fnNode["arguments"]
                    if argsNode.kind == JObject:
                      for k, v in argsNode:
                        storedTc.arguments[k] = v
                    elif argsNode.kind == JString:
                      try:
                        let parsed = parseJson(argsNode.getStr(""))
                        if parsed.kind == JObject:
                          for k, v in parsed:
                            storedTc.arguments[k] = v
                      except:
                        discard
                storedMsg.tool_calls.add(storedTc)
            session.messages.add(storedMsg)

        # Double-check the loaded session key matches the filename
        if session.key != sessionKey:
          # Session key mismatch, remove file
          try:
            removeFile(file)
          except:
            discard
          continue

        # Check session age
        let ageSeconds = getTime().toUnixFloat() - session.updated
        if ageSeconds > (MAX_SESSION_AGE_DAYS * 24 * 60 * 60):
          # Remove old session
          try:
            removeFile(file)
          except:
            discard
          continue
        result.sessions[session.key] = session
      except CatchableError as e:
        # Log error but continue loading other sessions
        discard

proc validateSessionKey*(key: string): bool =
  ## Validates that a session key is safe to use
  if key.len == 0 or key.len > MAX_SESSION_KEY_LENGTH:
    return false
  if not key.match(SESSION_KEY_PATTERN):
    return false
  # Prevent path traversal attempts
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

  # Validate session key
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
      # Remove oldest session
      var oldestKey = ""
      var oldestTime: float64 = high(float64)
      for k, s in sm.sessions:
        if s.created < oldestTime:
          oldestTime = s.created
          oldestKey = k
      if oldestKey != "":
        sm.sessions.del(oldestKey)
        # Try to remove the file
        if sm.storage != "":
          try:
            removeFile(sm.storage / (oldestKey & ".json"))
          except:
            discard

    let session = Session(
      key: safeKey,
      messages: @[],
      created: getTime().toUnixFloat(),
      updated: getTime().toUnixFloat()
    )
    sm.sessions[safeKey] = session
    return session

proc addFullMessage*(sm: SessionManager, sessionKey: string, msg: providers_types.Message) =
  ## Add a full message to a session
  var safeKey = sessionKey

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & sessionKey)

  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(safeKey):
    sm.sessions[safeKey] = Session(
      key: safeKey,
      messages: @[],
      created: getTime().toUnixFloat()
    )
  let session = sm.sessions[safeKey]
  session.messages.add(toStoredMessage(msg))
  session.updated = getTime().toUnixFloat()

proc addMessage*(sm: SessionManager, sessionKey, role, content: string) =
  ## Add a message to a session (legacy string-based API)
  let roleEnum = providers_types.parseMessageRole(role)
  let msg = providers_types.Message(role: roleEnum, content: some(content))
  sm.addFullMessage(sessionKey, msg)

proc getHistory*(sm: SessionManager, key: string): seq[providers_types.Message] =
  ## Get the message history for a session (converted to internal format)
  var safeKey = key

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(safeKey):
    return @[]

  result = @[]
  for storedMsg in sm.sessions[safeKey].messages:
    result.add(toInternalMessage(storedMsg))

proc getStoredHistory*(sm: SessionManager, key: string): seq[StoredMessage] =
  ## Get the raw stored message history for a session
  var safeKey = key

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(safeKey):
    return @[]
  return sm.sessions[safeKey].messages

proc getSummary*(sm: SessionManager, key: string): string =
  ## Get the summary for a session
  var safeKey = key

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(safeKey):
    return ""
  return sm.sessions[safeKey].summary

proc setSummary*(sm: SessionManager, key, summary: string) =
  ## Set the summary for a session
  var safeKey = key

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if sm.sessions.hasKey(safeKey):
    sm.sessions[safeKey].summary = summary
    sm.sessions[safeKey].updated = getTime().toUnixFloat()

proc truncateHistory*(sm: SessionManager, key: string, keepLast: int) =
  ## Truncate the message history to keep only the last N messages
  var safeKey = key

  # Validate session key
  if not validateSessionKey(safeKey):
    raise newException(ValueError, "Invalid session key: " & key)

  acquire(sm.lock)
  defer: release(sm.lock)

  if not sm.sessions.hasKey(safeKey): return

  let session = sm.sessions[safeKey]
  if session.messages.len <= keepLast: return
  session.messages = session.messages[session.messages.len - keepLast .. ^1]
  session.updated = getTime().toUnixFloat()

proc save*(sm: SessionManager, session: Session) =
  ## Save a session to storage
  if sm.storage == "": return

  # Validate session key
  if not validateSessionKey(session.key):
    raise newException(ValueError, "Invalid session key: " & session.key)

  acquire(sm.lock)
  defer: release(sm.lock)

  let safeStorage = sanitizePath(sm.storage)
  let path = safeStorage / (session.key & ".json")

  try:
    # Manual serialization for compatibility
    var jsonObj = newJObject()
    jsonObj["key"] = %session.key
    jsonObj["summary"] = %session.summary
    jsonObj["created"] = %session.created
    jsonObj["updated"] = %session.updated

    var messagesArr = newJArray()
    for msg in session.messages:
      var msgObj = newJObject()
      msgObj["role"] = %msg.role
      msgObj["content"] = %msg.content
      if msg.name.len > 0:
        msgObj["name"] = %msg.name
      if msg.tool_call_id.len > 0:
        msgObj["tool_call_id"] = %msg.tool_call_id

      if msg.tool_calls.len > 0:
        var tcArr = newJArray()
        for tc in msg.tool_calls:
          var tcObj = newJObject()
          tcObj["id"] = %tc.id
          tcObj["type"] = %tc.`type`

          var fnObj = newJObject()
          fnObj["name"] = %tc.name
          if tc.arguments.len > 0:
            fnObj["arguments"] = %tc.arguments
          tcObj["function"] = fnObj

          tcArr.add(tcObj)
        msgObj["tool_calls"] = tcArr

      messagesArr.add(msgObj)
    jsonObj["messages"] = messagesArr

    writeFile(path, $jsonObj)
  except IOError as e:
    raise newException(IOError, "Failed to save session: " & e.msg)
