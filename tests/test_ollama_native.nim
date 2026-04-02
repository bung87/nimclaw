# Ollama Native API Test
# This test explores using Ollama's native /api/generate endpoint
# with structured JSON output instead of OpenAI-compatible format.
#
# The native API has advantages for local models:
# 1. Better support for structured output via `format: "json"`
# 2. More control over generation parameters
# 3. Streaming support
# 4. Template support for consistent tool calling

import std/[json, strutils, tables, options, os]
import chronos
import chronos/apps/http/httpclient
import ../src/nimclaw/providers/types
import ../src/nimclaw/providers/adapters

const
  OLLAMA_API_BASE = "http://localhost:11434"
  TEST_MODEL = "qwen2.5-coder:7b"

# ============================================================================
# Native Ollama Request Format
# ============================================================================

type
  OllamaGenerateRequest* = object
    model*: string
    prompt*: string
    system*: Option[string]
    promptTemplate*: Option[string] # 'template' is a Nim keyword
    context*: Option[seq[int]]
    stream*: bool
    raw*: bool
    format*: Option[string]         # "json" for structured output
    options*: Option[JsonNode]      # Additional model parameters
    keepAlive*: Option[string]

  OllamaGenerateResponse* = object
    model*: string
    createdAt*: string
    response*: string
    done*: bool
    context*: Option[seq[int]]
    totalDuration*: Option[int64]
    loadDuration*: Option[int64]
    promptEvalCount*: Option[int]
    promptEvalDuration*: Option[int64]
    evalCount*: Option[int]
    evalDuration*: Option[int64]

proc toJson*(req: OllamaGenerateRequest): JsonNode =
  ## Convert request to JSON for native API
  result = %*{}
  result["model"] = %req.model
  result["prompt"] = %req.prompt
  result["stream"] = %req.stream
  result["raw"] = %req.raw

  if req.system.isSome:
    result["system"] = %req.system.get()
  if req.promptTemplate.isSome:
    result["template"] = %req.promptTemplate.get()
  if req.context.isSome:
    result["context"] = %req.context.get()
  if req.format.isSome:
    result["format"] = %req.format.get()
  if req.options.isSome:
    result["options"] = req.options.get()
  if req.keepAlive.isSome:
    result["keep_alive"] = %req.keepAlive.get()

proc fromJson*(node: JsonNode): OllamaGenerateResponse =
  ## Parse native API response
  result.model = node.getOrDefault("model").getStr("")
  result.createdAt = node.getOrDefault("created_at").getStr("")
  result.response = node.getOrDefault("response").getStr("")
  result.done = node.getOrDefault("done").getBool(false)

  if node.hasKey("context") and node["context"].kind == JArray:
    var ctx: seq[int] = @[]
    for item in node["context"]:
      ctx.add(item.getInt())
    result.context = some(ctx)

  if node.hasKey("total_duration"):
    result.totalDuration = some(node["total_duration"].getBiggestInt())
  if node.hasKey("load_duration"):
    result.loadDuration = some(node["load_duration"].getBiggestInt())
  if node.hasKey("prompt_eval_count"):
    result.promptEvalCount = some(node["prompt_eval_count"].getInt())
  if node.hasKey("prompt_eval_duration"):
    result.promptEvalDuration = some(node["prompt_eval_duration"].getBiggestInt())
  if node.hasKey("eval_count"):
    result.evalCount = some(node["eval_count"].getInt())
  if node.hasKey("eval_duration"):
    result.evalDuration = some(node["eval_duration"].getBiggestInt())

# ============================================================================
# Tool Calling with Native API
# ============================================================================

proc buildToolCallingPrompt*(systemPrompt, userMessage: string, tools: seq[ToolDefinition]): string =
  ## Build a prompt that instructs the model to output tool calls in JSON format
  result = ""

  if systemPrompt.len > 0:
    result.add(systemPrompt & "\n\n")

  if tools.len > 0:
    result.add("Available tools:\n")
    for tool in tools:
      result.add("- " & tool.function.name & ": " & tool.function.description & "\n")
    result.add("\n")
    result.add("If you need to use a tool, respond with ONLY a JSON object in this format:\n")
    result.add("{\"tool\": \"tool_name\", \"arguments\": {...}}\n")
    result.add("If no tool is needed, respond normally.\n\n")

  result.add("User: " & userMessage & "\n")
  result.add("Assistant: ")

proc parseToolCallFromResponse*(response: string): Option[tuple[name: string, arguments: Table[string, JsonNode]]] =
  ## Parse a tool call from the model's response
  let trimmed = response.strip()

  # Try to parse as JSON
  if trimmed.len > 0 and trimmed[0] == '{':
    try:
      let parsed = parseJson(trimmed)
      if parsed.kind == JObject:
        # Check for tool field
        if parsed.hasKey("tool") or parsed.hasKey("name"):
          let name = parsed.getOrDefault("tool").getStr(parsed.getOrDefault("name").getStr(""))
          var args = initTable[string, JsonNode]()

          if parsed.hasKey("arguments") and parsed["arguments"].kind == JObject:
            for k, v in parsed["arguments"]:
              args[k] = v

          return some((name: name, arguments: args))
    except CatchableError:
      discard

  return none(tuple[name: string, arguments: Table[string, JsonNode]])

# ============================================================================
# Test: Native API vs OpenAI-compatible
# ============================================================================

proc testNativeGenerate*(model: string = TEST_MODEL): Future[bool] {.async.} =
  ## Test the native /api/generate endpoint
  echo "Testing Ollama native API with model: ", model

  let session = HttpSessionRef.new()
  let url = OLLAMA_API_BASE & "/api/generate"

  let request = OllamaGenerateRequest(
    model: model,
    prompt: "What is 2+2? Answer with a single number.",
    stream: false,
    raw: false,
    format: none(string)
  )

  let bodyStr = $toJson(request)
  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))

  let addressRes = session.getAddress(url)
  if addressRes.isErr:
    echo "Failed to resolve URL: ", url
    return false

  let address = addressRes.get()
  let httpRequest = HttpClientRequestRef.new(
    session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )

  try:
    let response = await httpRequest.send()
    let bodyBytes = await response.getBodyBytes()
    let bodyText = cast[string](bodyBytes)

    if response.status >= 200 and response.status < 300:
      let jsonResp = parseJson(bodyText)
      let ollamaResp = fromJson(jsonResp)
      echo "Response: ", ollamaResp.response
      echo "Done: ", ollamaResp.done
      if ollamaResp.evalCount.isSome:
        echo "Eval count: ", ollamaResp.evalCount.get()
      return true
    else:
      echo "Error: ", response.status, " - ", bodyText
      return false
  except CatchableError as e:
    echo "Exception: ", e.msg
    return false

proc testStructuredOutput*(model: string = TEST_MODEL): Future[bool] {.async.} =
  ## Test structured JSON output
  echo "\nTesting structured JSON output..."

  let session = HttpSessionRef.new()
  let url = OLLAMA_API_BASE & "/api/generate"

  let request = OllamaGenerateRequest(
    model: model,
    prompt: "List 2 programming languages with their creation years",
    stream: false,
    raw: false,
    format: some("json") # Request JSON output
  )

  let bodyStr = $toJson(request)
  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))

  let addressRes = session.getAddress(url)
  if addressRes.isErr:
    echo "Failed to resolve URL"
    return false

  let address = addressRes.get()
  let httpRequest = HttpClientRequestRef.new(
    session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )

  try:
    let response = await httpRequest.send()
    let bodyBytes = await response.getBodyBytes()
    let bodyText = cast[string](bodyBytes)

    if response.status >= 200 and response.status < 300:
      let jsonResp = parseJson(bodyText)
      let ollamaResp = fromJson(jsonResp)
      echo "JSON Response:"
      echo ollamaResp.response

      # Try to parse as valid JSON
      try:
        let parsed = parseJson(ollamaResp.response)
        echo "Valid JSON: ", parsed.kind
        return true
      except:
        echo "Invalid JSON returned"
        return false
    else:
      echo "Error: ", bodyText
      return false
  except CatchableError as e:
    echo "Exception: ", e.msg
    return false

proc testToolCalling*(model: string = TEST_MODEL): Future[bool] {.async.} =
  ## Test tool calling via native API
  echo "\nTesting tool calling prompt..."

  let session = HttpSessionRef.new()
  let url = OLLAMA_API_BASE & "/api/generate"

  let tools = @[
    ToolDefinition(
      `type`: "function",
      function: ToolFunctionDefinition(
        name: "list_dir",
        description: "List files in a directory",
        parameters: initTable[string, JsonNode]()
    )
  ),
    ToolDefinition(
      `type`: "function",
      function: ToolFunctionDefinition(
        name: "read_file",
        description: "Read a file's contents",
        parameters: initTable[string, JsonNode]()
    )
  )
  ]

  let prompt = buildToolCallingPrompt(
    "You are a helpful assistant.",
    "What files are in the current directory?",
    tools
  )

  let request = OllamaGenerateRequest(
    model: model,
    prompt: prompt,
    stream: false,
    raw: false,
    format: some("json") # Force JSON output
  )

  let bodyStr = $toJson(request)
  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))

  let addressRes = session.getAddress(url)
  if addressRes.isErr:
    return false

  let address = addressRes.get()
  let httpRequest = HttpClientRequestRef.new(
    session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )

  try:
    let response = await httpRequest.send()
    let bodyBytes = await response.getBodyBytes()
    let bodyText = cast[string](bodyBytes)

    if response.status >= 200 and response.status < 300:
      let jsonResp = parseJson(bodyText)
      let ollamaResp = fromJson(jsonResp)
      echo "Response:"
      echo ollamaResp.response

      # Try to parse as tool call
      let toolCall = parseToolCallFromResponse(ollamaResp.response)
      if toolCall.isSome:
        echo "Parsed tool call: ", toolCall.get().name
        return true
      else:
        echo "No tool call detected (normal response)"
        return true
    else:
      echo "Error: ", bodyText
      return false
  except CatchableError as e:
    echo "Exception: ", e.msg
    return false

# ============================================================================
# Main test runner
# ============================================================================

when isMainModule:
  echo "=========================================="
  echo "Ollama Native API Test Suite"
  echo "=========================================="
  echo "Make sure Ollama is running on ", OLLAMA_API_BASE
  echo ""

  let model = if paramCount() > 0: paramStr(1) else: TEST_MODEL

  var results: seq[tuple[name: string, passed: bool]] = @[]

  # Test 1: Basic generation
  let test1 = waitFor testNativeGenerate(model)
  results.add(("Basic generation", test1))

  # Test 2: Structured JSON output
  let test2 = waitFor testStructuredOutput(model)
  results.add(("Structured JSON", test2))

  # Test 3: Tool calling prompt
  let test3 = waitFor testToolCalling(model)
  results.add(("Tool calling", test3))

  # Summary
  echo "\n=========================================="
  echo "Test Results:"
  echo "=========================================="
  var passed = 0
  var failed = 0
  for (name, result) in results:
    if result:
      echo "✓ ", name
      passed.inc()
    else:
      echo "✗ ", name
      failed.inc()

  echo "\nPassed: ", passed, "/", results.len

  if failed > 0:
    quit(1)
