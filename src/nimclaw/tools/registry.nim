import chronos
import std/[tables, json, locks, times]
import types
import ../logger
import ../providers/types as providers_types

type
  ToolRegistry* = ref object
    tools: Table[string, Tool]
    lock: Lock

proc newToolRegistry*(): ToolRegistry =
  var tr = ToolRegistry(tools: initTable[string, Tool]())
  initLock(tr.lock)
  return tr

proc register*(r: ToolRegistry, tool: Tool) =
  acquire(r.lock)
  defer: release(r.lock)
  r.tools[tool.name()] = tool

proc get*(r: ToolRegistry, name: string): (Tool, bool) =
  acquire(r.lock)
  defer: release(r.lock)
  if r.tools.hasKey(name):
    return (r.tools[name], true)
  else:
    return (nil, false)

proc list*(r: ToolRegistry): seq[string] =
  acquire(r.lock)
  defer: release(r.lock)
  for k in r.tools.keys:
    result.add(k)

proc count*(r: ToolRegistry): int =
  acquire(r.lock)
  defer: release(r.lock)
  r.tools.len

proc getSummaries*(r: ToolRegistry): seq[string] =
  acquire(r.lock)
  defer: release(r.lock)
  for tool in r.tools.values:
    result.add("- `" & tool.name() & "` - " & tool.description())

proc toolToSchema*(tool: Tool): ToolDefinition {.raises: [].} =
  ToolDefinition(
    `type`: "function",
    function: ToolFunctionDefinition(
      name: tool.name(),
      description: tool.description(),
      parameters: tool.parameters()
    )
  )

proc getDefinitions*(r: ToolRegistry): seq[ToolDefinition] {.raises: [].} =
  acquire(r.lock)
  defer: release(r.lock)
  for tool in r.tools.values:
    result.add(toolToSchema(tool))

proc getDefinitionsFiltered*(r: ToolRegistry, allowedNames: seq[string]): seq[ToolDefinition] {.raises: [].} =
  if allowedNames.len == 0:
    return getDefinitions(r)
  acquire(r.lock)
  defer: release(r.lock)
  for name in allowedNames:
    if r.tools.hasKey(name):
      try:
        result.add(toolToSchema(r.tools[name]))
      except KeyError:
        discard

proc executeWithContext*(r: ToolRegistry, name: string, args: Table[string, JsonNode], channel, chatID: string): Future[
    string] {.async.} =
  info "Tool execution started", topic = "tool", tool = name, args = $args

  let (tool, ok) = r.get(name)
  if not ok:
    error "Tool not found", topic = "tool", tool = name
    return "Error: tool '" & name & "' not found"

  if tool of ContextualTool and channel != "" and chatID != "":
    try:
      (cast[ContextualTool](tool)).setContext(channel, chatID)
    except CatchableError as e:
      warn "Failed to set tool context", topic = "tool", tool = name, error = e.msg

  let start = now()
  var toolResult = ""
  try:
    toolResult = await tool.execute(args)
  except CatchableError as e:
    let duration = (now() - start).inMilliseconds
    error "Tool execution failed", topic = "tool", tool = name, duration = $duration, error = e.msg
    return "Error: " & e.msg

  let duration = (now() - start).inMilliseconds
  info "Tool execution completed", topic = "tool", tool = name, duration_ms = $duration, result_length = $toolResult.len
  return toolResult
