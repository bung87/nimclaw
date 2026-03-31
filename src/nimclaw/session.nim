import std/[os, times, locks, tables, strutils]
import pkg/regex except re
import jsony
import providers/types as providers_types
import ./security

type
  Session* = ref object
    key*: string
    messages*: seq[providers_types.Message]
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
        let data = readFile(file)
        let session = data.fromJson(Session)
        # Validate loaded session key
        discard validateSessionKey(session.key)
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
      except Exception as e:
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
  var result = key
  result = result.multiReplace(("../", ""), ("..", ""), ("\\", ""), ("/", "_"), ("|", "_"), ("*", "_"), ("?", "_"))
  result = result.replace(re2"[^a-zA-Z0-9:_\-]", "_")
  if result.len > MAX_SESSION_KEY_LENGTH:
    result = result[0..<MAX_SESSION_KEY_LENGTH]
  return result

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
  session.messages.add(msg)
  session.updated = getTime().toUnixFloat()

proc addMessage*(sm: SessionManager, sessionKey, role, content: string) =
  ## Add a message to a session
  sm.addFullMessage(sessionKey, providers_types.Message(role: role, content: content))

proc getHistory*(sm: SessionManager, key: string): seq[providers_types.Message] =
  ## Get the message history for a session
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
    writeFile(path, session.toJson())
  except IOError as e:
    raise newException(IOError, "Failed to save session: " & e.msg)
