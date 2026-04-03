import std/[options, tables, json]
import chronos
import chronicles

type
  # ============================================================================
  # Core Schema (OpenAI-compatible, provider-agnostic)
  # ============================================================================

  ToolCall* = object
    id*: string
    name*: string
    arguments*: Table[string, JsonNode]

  MessageRole* = enum
    mrSystem, mrUser, mrAssistant, mrTool

  Message* = object
    role*: MessageRole
    content*: Option[string]
    name*: Option[string]       # function name (tool)
    toolCalls*: seq[ToolCall]   # assistant → tools
    toolCallId*: Option[string] # tool → assistant

  UsageInfo* = object
    prompt_tokens*: int
    completion_tokens*: int
    total_tokens*: int

  LLMResponse* = object
    content*: Option[string]
    reasoning*: Option[string]
    tool_calls*: seq[ToolCall]
    finish_reason*: string
    usage*: UsageInfo

  # ============================================================================
  # Tool Definitions (for sending to LLM)
  # ============================================================================

  ToolFunctionDefinition* = object
    name*: string
    description*: string
    parameters*: Table[string, JsonNode]

  ToolDefinition* = object
    `type`*: string
    function*: ToolFunctionDefinition

  # ============================================================================
  # Adapter Layer
  # ============================================================================

  ProviderAdapter* = ref object of RootObj

  # ============================================================================
  # Provider Base
  # ============================================================================

  LLMProvider* = ref object of RootObj

# Message Role Helpers

proc toString*(role: MessageRole): string =
  case role:
  of mrSystem: "system"
  of mrUser: "user"
  of mrAssistant: "assistant"
  of mrTool: "tool"

proc parseMessageRole*(s: string): MessageRole =
  case s:
  of "system": mrSystem
  of "user": mrUser
  of "assistant": mrAssistant
  of "tool": mrTool
  else: mrUser # default fallback

# Core Message Serialization (OpenAI format)

proc toOpenAIMessage*(msg: Message): JsonNode =
  ## Convert internal Message to OpenAI API format
  var j = %*{
    "role": msg.role.toString()
  }

  if msg.content.isSome:
    j["content"] = %msg.content.get()

  if msg.name.isSome:
    j["name"] = %msg.name.get()

  if msg.toolCalls.len > 0:
    var arr = newJArray()
    for tc in msg.toolCalls:
      arr.add(%*{
        "type": "function",
        "id": tc.id,
        "function": {
          "name": tc.name,
          "arguments": $(%tc.arguments) # Always string
        }
      })
    j["tool_calls"] = arr

  if msg.toolCallId.isSome:
    j["tool_call_id"] = %msg.toolCallId.get()

  return j

proc messagesToJson*(msgs: seq[Message]): JsonNode =
  ## Convert sequence of messages to OpenAI API format
  var arr = newJArray()
  for msg in msgs:
    arr.add(msg.toOpenAIMessage())
  return arr

proc fromOpenAIMessage*(j: JsonNode): Message =
  ## Parse OpenAI API message format to internal Message
  result = Message()

  if j.hasKey("role"):
    result.role = parseMessageRole(j["role"].getStr(""))

  if j.hasKey("content") and j["content"].kind != JNull:
    let content = j["content"].getStr("")
    if content.len > 0:
      result.content = some(content)

  if j.hasKey("name"):
    result.name = some(j["name"].getStr(""))

  if j.hasKey("tool_calls") and j["tool_calls"].kind == JArray:
    for tc in j["tool_calls"]:
      if tc.hasKey("function"):
        let fn = tc["function"]
        var toolCall = ToolCall(
          id: tc.getOrDefault("id").getStr(""),
          name: fn.getOrDefault("name").getStr("")
        )

        let argsNode = fn.getOrDefault("arguments")
        case argsNode.kind:
        of JString:
          try:
            let parsed = parseJson(argsNode.getStr(""))
            if parsed.kind == JObject:
              for k, v in parsed:
                toolCall.arguments[k] = v
          except CatchableError as e:
            warn "Failed to parse tool arguments", msg = e.msg
        of JObject:
          for k, v in argsNode:
            toolCall.arguments[k] = v
        else:
          discard

        result.toolCalls.add(toolCall)

  if j.hasKey("tool_call_id"):
    result.toolCallId = some(j["tool_call_id"].getStr(""))

# Legacy Compatibility Helpers

proc toLegacyRole*(role: MessageRole): string =
  ## For backward compatibility with string-based roles
  role.toString()

proc fromLegacyRole*(role: string): MessageRole =
  ## For backward compatibility with string-based roles
  parseMessageRole(role)

# Adapter Methods (Base)

method normalizeResponse*(a: ProviderAdapter, json: JsonNode): LLMResponse {.base, gcsafe, raises: [].} =
  ## Base method - should be overridden by specific adapters
  discard

method normalizeMessage*(a: ProviderAdapter, msg: Message): JsonNode {.base.} =
  ## Default normalization: use OpenAI format
  msg.toOpenAIMessage()

# Provider Base Methods

method chat*(p: LLMProvider, messages: seq[Message], tools: seq[ToolDefinition],
             model: string, options: Table[string, JsonNode]): Future[LLMResponse] {.base, async.} =
  discard

method getDefaultModel*(p: LLMProvider): string {.base, gcsafe, raises: [].} =
  return ""
