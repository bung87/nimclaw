## Checkpoint Management for Nimclaw
##
## Persists agent loop execution state for crash recovery and time-travel debugging.

import std/[os, times, json, tables, sequtils, strutils, options, algorithm]
import ../providers/types as providers_types
import ../logger

type
  Checkpoint* = object
    sessionKey*: string
    iteration*: int
    turn*: int
    messages*: seq[providers_types.Message]
    pendingToolCalls*: seq[providers_types.ToolCall]
    accumulatedContent*: string
    accumulatedReasoning*: string
    createdAt*: int64

  CheckpointManager* = ref object
    checkpointDir*: string
    maxCheckpointsPerSession*: int

  CheckpointError* = object of CatchableError

proc newCheckpointManager*(workspace: string, maxCheckpoints: int = 10): CheckpointManager =
  ## Create new checkpoint manager
  let checkpointDir = workspace / "checkpoints"
  if not dirExists(checkpointDir):
    try:
      createDir(checkpointDir)
    except CatchableError as e:
      warn "Failed to create checkpoints directory", path = checkpointDir, error = e.msg

  CheckpointManager(
    checkpointDir: checkpointDir,
    maxCheckpointsPerSession: maxCheckpoints
  )

proc getSessionCheckpointDir(cm: CheckpointManager, sessionKey: string): string =
  ## Get checkpoint directory for a session
  # Sanitize session key for filesystem
  var safeKey = sessionKey.replace("/", "_").replace("\\", "_")
  result = cm.checkpointDir / safeKey

proc messageToJson(msg: providers_types.Message): JsonNode =
  ## Convert Message to JSON
  result = %*{}
  result["role"] = %msg.role.toString()
  if msg.content.isSome:
    result["content"] = %msg.content.get()
  if msg.name.isSome:
    result["name"] = %msg.name.get()
  if msg.toolCallId.isSome:
    result["tool_call_id"] = %msg.toolCallId.get()
  if msg.toolCalls.len > 0:
    var tcArray = newJArray()
    for tc in msg.toolCalls:
      tcArray.add(%*{
        "id": tc.id,
        "name": tc.name,
        "arguments": tc.arguments
      })
    result["tool_calls"] = tcArray

proc messageFromJson(j: JsonNode): providers_types.Message =
  ## Convert JSON to Message
  result.role = providers_types.parseMessageRole(j["role"].getStr("user"))
  if j.hasKey("content"):
    result.content = some(j["content"].getStr(""))
  if j.hasKey("name"):
    result.name = some(j["name"].getStr(""))
  if j.hasKey("tool_call_id"):
    result.toolCallId = some(j["tool_call_id"].getStr(""))
  if j.hasKey("tool_calls") and j["tool_calls"].kind == JArray:
    for tcNode in j["tool_calls"]:
      var tc = providers_types.ToolCall(
        id: tcNode["id"].getStr(""),
        name: tcNode["name"].getStr(""),
        arguments: initTable[string, JsonNode]()
      )
      if tcNode.hasKey("arguments") and tcNode["arguments"].kind == JObject:
        for k, v in tcNode["arguments"]:
          tc.arguments[k] = v
      result.toolCalls.add(tc)

proc checkpointToJson(cp: Checkpoint): JsonNode =
  ## Convert Checkpoint to JSON
  result = %*{
    "sessionKey": cp.sessionKey,
    "iteration": cp.iteration,
    "turn": cp.turn,
    "accumulatedContent": cp.accumulatedContent,
    "accumulatedReasoning": cp.accumulatedReasoning,
    "createdAt": cp.createdAt
  }

  # Add messages
  var msgArray = newJArray()
  for msg in cp.messages:
    msgArray.add(messageToJson(msg))
  result["messages"] = msgArray

  # Add pending tool calls
  var tcArray = newJArray()
  for tc in cp.pendingToolCalls:
    tcArray.add(%*{
      "id": tc.id,
      "name": tc.name,
      "arguments": tc.arguments
    })
  result["pendingToolCalls"] = tcArray

proc checkpointFromJson(j: JsonNode): Checkpoint =
  ## Convert JSON to Checkpoint
  result.sessionKey = j["sessionKey"].getStr("")
  result.iteration = j["iteration"].getInt(0)
  result.turn = j["turn"].getInt(0)
  result.accumulatedContent = j["accumulatedContent"].getStr("")
  result.accumulatedReasoning = j["accumulatedReasoning"].getStr("")
  result.createdAt = j["createdAt"].getBiggestInt(0)

  if j.hasKey("messages") and j["messages"].kind == JArray:
    for msgNode in j["messages"]:
      result.messages.add(messageFromJson(msgNode))

  if j.hasKey("pendingToolCalls") and j["pendingToolCalls"].kind == JArray:
    for tcNode in j["pendingToolCalls"]:
      var tc = providers_types.ToolCall(
        id: tcNode["id"].getStr(""),
        name: tcNode["name"].getStr(""),
        arguments: initTable[string, JsonNode]()
      )
      if tcNode.hasKey("arguments") and tcNode["arguments"].kind == JObject:
        for k, v in tcNode["arguments"]:
          tc.arguments[k] = v
      result.pendingToolCalls.add(tc)

proc cleanupOldCheckpoints(cm: CheckpointManager, sessionKey: string) =
  ## Remove old checkpoints, keeping only the most recent ones
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  if not dirExists(sessionDir):
    return

  var checkpoints: seq[tuple[turn, iteration: int, path: string]] = @[]

  for file in walkFiles(sessionDir / "*.json"):
    let filename = extractFilename(file)
    # Parse turn_iteration.json
    let parts = filename.split("_")
    if parts.len >= 2:
      try:
        let turn = parseInt(parts[0])
        let iteration = parseInt(parts[1].split(".")[0])
        checkpoints.add((turn, iteration, file))
      except ValueError:
        continue

  # Sort by turn then iteration (descending)
  checkpoints.sort(proc(a, b: auto): int =
    if a.turn != b.turn:
      return b.turn - a.turn
    return b.iteration - a.iteration
  )

  # Remove excess checkpoints
  if checkpoints.len > cm.maxCheckpointsPerSession:
    for i in cm.maxCheckpointsPerSession ..< checkpoints.len:
      try:
        removeFile(checkpoints[i].path)
        debug "Removed old checkpoint", path = checkpoints[i].path
      except CatchableError as e:
        warn "Failed to remove old checkpoint", path = checkpoints[i].path, error = e.msg

proc save*(cm: CheckpointManager, cp: Checkpoint) =
  ## Save a checkpoint to disk
  let sessionDir = cm.getSessionCheckpointDir(cp.sessionKey)
  if not dirExists(sessionDir):
    try:
      createDir(sessionDir)
    except CatchableError as e:
      raise newException(CheckpointError, "Failed to create checkpoint directory: " & e.msg)

  let filename = "$1_$2.json".format(cp.turn, cp.iteration)
  let filepath = sessionDir / filename

  try:
    writeFile(filepath, $(checkpointToJson(cp)))
    debug "Saved checkpoint", session = cp.sessionKey, turn = cp.turn, iteration = cp.iteration
  except CatchableError as e:
    raise newException(CheckpointError, "Failed to write checkpoint: " & e.msg)

  # Cleanup old checkpoints for this session
  cm.cleanupOldCheckpoints(cp.sessionKey)

proc load*(cm: CheckpointManager, sessionKey: string, turn, iteration: int): Checkpoint =
  ## Load a specific checkpoint
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  let filename = "$1_$2.json".format(turn, iteration)
  let filepath = sessionDir / filename

  if not fileExists(filepath):
    raise newException(CheckpointError, "Checkpoint not found: " & filepath)

  try:
    let jsonData = readFile(filepath)
    result = checkpointFromJson(parseJson(jsonData))
  except CatchableError as e:
    raise newException(CheckpointError, "Failed to load checkpoint: " & e.msg)

proc loadLatest*(cm: CheckpointManager, sessionKey: string): Checkpoint =
  ## Load the most recent checkpoint for a session
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  if not dirExists(sessionDir):
    raise newException(CheckpointError, "No checkpoints for session: " & sessionKey)

  var latest: tuple[turn, iteration: int, path: string] = (-1, -1, "")

  for file in walkFiles(sessionDir / "*.json"):
    let filename = extractFilename(file)
    let parts = filename.split("_")
    if parts.len >= 2:
      try:
        let turn = parseInt(parts[0])
        let iteration = parseInt(parts[1].split(".")[0])
        if turn > latest.turn or (turn == latest.turn and iteration > latest.iteration):
          latest = (turn, iteration, file)
      except ValueError:
        continue

  if latest.path == "":
    raise newException(CheckpointError, "No valid checkpoints for session: " & sessionKey)

  try:
    let jsonData = readFile(latest.path)
    result = checkpointFromJson(parseJson(jsonData))
  except CatchableError as e:
    raise newException(CheckpointError, "Failed to load checkpoint: " & e.msg)

proc hasCheckpoints*(cm: CheckpointManager, sessionKey: string): bool =
  ## Check if a session has any checkpoints
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  if not dirExists(sessionDir):
    return false

  for _ in walkFiles(sessionDir / "*.json"):
    return true
  return false

proc delete*(cm: CheckpointManager, sessionKey: string, turn, iteration: int) =
  ## Delete a specific checkpoint
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  let filename = "$1_$2.json".format(turn, iteration)
  let filepath = sessionDir / filename

  if fileExists(filepath):
    try:
      removeFile(filepath)
      debug "Deleted checkpoint", session = sessionKey, turn = turn, iteration = iteration
    except CatchableError as e:
      warn "Failed to delete checkpoint", path = filepath, error = e.msg

proc deleteAll*(cm: CheckpointManager, sessionKey: string) =
  ## Delete all checkpoints for a session
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  if not dirExists(sessionDir):
    return

  for file in walkFiles(sessionDir / "*.json"):
    try:
      removeFile(file)
    except CatchableError as e:
      warn "Failed to delete checkpoint", path = file, error = e.msg

  # Try to remove directory
  try:
    removeDir(sessionDir)
  except CatchableError:
    discard

  info "Deleted all checkpoints", session = sessionKey

proc list*(cm: CheckpointManager, sessionKey: string): seq[tuple[turn, iteration: int, createdAt: int64]] =
  ## List all checkpoints for a session
  let sessionDir = cm.getSessionCheckpointDir(sessionKey)
  if not dirExists(sessionDir):
    return @[]

  for file in walkFiles(sessionDir / "*.json"):
    let filename = extractFilename(file)
    let parts = filename.split("_")
    if parts.len >= 2:
      try:
        let turn = parseInt(parts[0])
        let iteration = parseInt(parts[1].split(".")[0])

        # Load just the timestamp
        let jsonData = readFile(file)
        let j = parseJson(jsonData)
        let createdAt = j["createdAt"].getBiggestInt(0)

        result.add((turn, iteration, createdAt))
      except CatchableError:
        continue

  # Sort by turn then iteration
  result.sort(proc(a, b: auto): int =
    if a.turn != b.turn:
      return a.turn - b.turn
    return a.iteration - b.iteration
  )
