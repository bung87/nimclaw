import std/[tables, json, options, strutils, times, re]
import chronicles
import types

# Helper Functions

proc extractThinkContent*(content: string): tuple[thinking: string, response: string] {.raises: [].} =
  ## Extract <think>...</think> content from reasoning models (like DeepSeek-R1).
  ## Returns the thinking content separately from the main response.
  try:
    var extractedThinking = ""
    var cleanedResponse = content

    # Find all <think>...</think> blocks
    let thinkPattern = re"(?s)<think>(.*?)</think>"
    var start = 0
    while true:
      let bounds = cleanedResponse.findBounds(thinkPattern, start)
      if bounds[0] == -1:
        break
      let matchContent = cleanedResponse[bounds[0]..bounds[1]]
      # Extract inner content
      let innerStart = matchContent.find(">") + 1
      let innerEnd = matchContent.rfind("<") - 1
      if innerEnd >= innerStart:
        let inner = matchContent[innerStart..innerEnd].strip()
        if inner.len > 0:
          if extractedThinking.len > 0:
            extractedThinking.add("\n\n")
          extractedThinking.add(inner)
      # Remove the think block from response
      cleanedResponse = cleanedResponse[0..<bounds[0]] & cleanedResponse[(bounds[1]+1)..^1]

    (thinking: extractedThinking, response: cleanedResponse.strip())
  except CatchableError:
    (thinking: "", response: content)

proc formatWithThinking*(thinking, response: string): string {.raises: [].} =
  ## Format content with thinking section as labeled text
  if thinking.len == 0:
    return response

  var formatted = "💭 Thinking:\n" & thinking.indent(2) & "\n\n"
  if response.len > 0:
    formatted.add(response)
  return formatted

proc safeParseJson*(s: string): JsonNode {.raises: [].} =
  ## Safely parse JSON, return empty object on error
  try:
    return parseJson(s)
  except CatchableError as e:
    warn "Failed to parse JSON", msg = e.msg
    return newJObject()

proc normalizeArguments*(argsNode: JsonNode): Table[string, JsonNode] {.raises: [].} =
  ## Normalize arguments that can be either string or object
  try:
    case argsNode.kind:
    of JString:
      let parsed = safeParseJson(argsNode.getStr(""))
      if parsed.kind == JObject:
        for k, v in parsed:
          result[k] = v
    of JObject:
      for k, v in argsNode:
        result[k] = v
    else:
      discard
  except CatchableError as e:
    warn "Failed to normalize arguments", msg = e.msg
  return result

proc tryParseToolCallFromContent*(content: string): seq[ToolCall] {.raises: [].} =
  ## Ollama-specific: Some models output tool calls as JSON in content field
  ## instead of using the proper tool_calls array. This parses that as a fallback.
  ##
  ## STRICT: Only handles clean JSON tool calls that:
  ## 1. Start with '{' and end with '}'
  ## 2. Have no newlines (single line only)
  ## 3. Are valid JSON with {"name": "...", "arguments": {...}} format
  ##
  ## Mixed text+JSON is NOT handled because there's no reliable way to distinguish
  ## between natural language containing JSON and an actual tool call.
  var calls: seq[ToolCall] = @[]
  let trimmed = content.strip()

  if trimmed.len == 0:
    return calls

  # Only try if content starts with '{' and ends with '}' (JSON object)
  if trimmed[0] != '{' or trimmed[^1] != '}':
    return calls

  # STRICT: Check for newlines - if present, it's mixed text+JSON, skip parsing.
  if '\n' in trimmed:
    return calls

  let parsed = safeParseJson(trimmed)
  if parsed.kind != JObject:
    return calls

  # Look for {"name": "...", "arguments": {...}} format
  if parsed.hasKey("name") and parsed.hasKey("arguments"):
    var toolCall = ToolCall(
      id: "call_" & $getTime(),
      name: parsed.getOrDefault("name").getStr("")
    )
    let args = normalizeArguments(parsed.getOrDefault("arguments"))
    for k, v in args:
      toolCall.arguments[k] = v
    calls.add(toolCall)

  return calls



# OpenAI Adapter (also works for OpenRouter, Groq, vLLM, etc.)

type
  OpenAIAdapter* = ref object of ProviderAdapter

method normalizeResponse*(a: OpenAIAdapter, json: JsonNode): LLMResponse {.gcsafe, raises: [].} =
  ## Normalize OpenAI-compatible response to internal schema
  var resp = LLMResponse()

  try:
    if json.hasKey("choices") and json["choices"].kind == JArray and json["choices"].len > 0:
      let choice = json["choices"][0]

      if choice.hasKey("message") and choice["message"].kind == JObject:
        let msg = choice["message"]

        # Extract reasoning_content if provided (OpenAI-compatible providers like OpenRouter)
        if msg.hasKey("reasoning_content"):
          let reasoning = msg["reasoning_content"].getStr("").strip()
          if reasoning.len > 0:
            resp.reasoning = some(reasoning)

        # Extract content (and handle <think> tags from reasoning models)
        var hasContent = false
        var contentStr = ""
        if msg.hasKey("content") and msg["content"].kind != JNull:
          contentStr = msg["content"].getStr("")
          if contentStr.len > 0:
            # Extract and format thinking content
            let (thinking, cleanContent) = extractThinkContent(contentStr)
            contentStr = formatWithThinking(thinking, cleanContent)
            if contentStr.len > 0:
              resp.content = some(contentStr)
              hasContent = true

        # Extract tool calls
        if msg.hasKey("tool_calls") and msg["tool_calls"].kind == JArray:
          var parsedAny = false

          for tc in msg["tool_calls"]:
            if tc.kind != JObject or not tc.hasKey("function"):
              continue

            let fn = tc["function"]
            if fn.kind != JObject:
              continue

            var toolCall = ToolCall(
              id: tc.getOrDefault("id").getStr(""),
              name: fn.getOrDefault("name").getStr("")
            )

            let argsNode = fn.getOrDefault("arguments")
            let args = normalizeArguments(argsNode)

            if args.len > 0 or toolCall.name.len > 0:
              for k, v in args:
                toolCall.arguments[k] = v

              resp.tool_calls.add(toolCall)
              parsedAny = true



        if choice.hasKey("finish_reason"):
          resp.finish_reason = choice["finish_reason"].getStr("stop")
        else:
          resp.finish_reason = "stop"

    # Extract usage info
    if json.hasKey("usage") and json["usage"].kind == JObject:
      let usage = json["usage"]
      resp.usage = UsageInfo(
        prompt_tokens: usage.getOrDefault("prompt_tokens").getInt(),
        completion_tokens: usage.getOrDefault("completion_tokens").getInt(),
        total_tokens: usage.getOrDefault("total_tokens").getInt()
      )
  except CatchableError as e:
    warn "Adapter failed to normalize response", msg = e.msg

  return resp

# Ollama Adapter

type
  OllamaAdapter* = ref object of ProviderAdapter

method normalizeResponse*(a: OllamaAdapter, json: JsonNode): LLMResponse {.gcsafe, raises: [].} =
  ## Normalize Ollama response to internal schema
  ## Handles both native Ollama format and OpenAI-compatible format
  var resp = LLMResponse()

  try:
    # Ollama can return responses in two formats:
    # 1. Native format: json["message"] with content, tool_calls, etc.
    # 2. OpenAI-compatible format: json["choices"][0]["message"]

    var msg: JsonNode
    var msgFound = false

    # Try native format first
    if json.hasKey("message") and json["message"].kind == JObject:
      msg = json["message"]
      msgFound = true
    # Fall back to OpenAI-compatible format
    elif json.hasKey("choices") and json["choices"].kind == JArray and json["choices"].len > 0:
      let choice = json["choices"][0]
      if choice.hasKey("message") and choice["message"].kind == JObject:
        msg = choice["message"]
        msgFound = true

    if msgFound:
      # Extract content (and handle <think> tags from reasoning models)
      if msg.hasKey("content"):
        var content = msg["content"].getStr("")
        if content.len > 0:
          # Extract and format thinking content
          let (thinking, cleanContent) = extractThinkContent(content)
          content = formatWithThinking(thinking, cleanContent)
          if content.len > 0:
            resp.content = some(content)

      # Fallback: some Ollama models (e.g., gemma4) return empty content but include reasoning
      if msg.hasKey("reasoning"):
        let reasoning = msg["reasoning"].getStr("").strip()
        if reasoning.len > 0:
          resp.reasoning = some(reasoning)

      # Extract tool_calls (standard format)
      if msg.hasKey("tool_calls") and msg["tool_calls"].kind == JArray:
        for tc in msg["tool_calls"]:
          if tc.kind != JObject or not tc.hasKey("function"):
            continue

          let fn = tc["function"]
          if fn.kind != JObject:
            continue

          var toolCall = ToolCall(
            id: tc.getOrDefault("id").getStr(""),
            name: fn.getOrDefault("name").getStr("")
          )

          let argsNode = fn.getOrDefault("arguments")
          let args = normalizeArguments(argsNode)
          for k, v in args:
            toolCall.arguments[k] = v

          resp.tool_calls.add(toolCall)

      # Fallback: Ollama sometimes uses tool_name (non-standard)
      if resp.tool_calls.len == 0 and msg.hasKey("tool_name"):
        var call = ToolCall(
          id: "call_fallback_" & $getTime(),
          name: msg["tool_name"].getStr("")
        )

        # Try to extract arguments from tool_arguments if present
        if msg.hasKey("tool_arguments") and msg["tool_arguments"].kind == JObject:
          let args = msg["tool_arguments"]
          for k, v in args:
            call.arguments[k] = v

        resp.tool_calls.add(call)

      # Ollama-specific: Some models (like qwen2.5-coder) output tool calls as JSON in content
      # instead of using the proper tool_calls array. Parse content as a last resort.
      if resp.tool_calls.len == 0 and resp.content.isSome:
        let calls = tryParseToolCallFromContent(resp.content.get())
        for c in calls:
          resp.tool_calls.add(c)

    resp.finish_reason = "stop"
  except CatchableError as e:
    warn "Adapter failed to normalize response", msg = e.msg

  return resp

# Anthropic Adapter

type
  AnthropicAdapter* = ref object of ProviderAdapter

method normalizeResponse*(a: AnthropicAdapter, json: JsonNode): LLMResponse {.gcsafe, raises: [].} =
  ## Normalize Anthropic Claude response to internal schema
  var resp = LLMResponse()

  try:
    if json.hasKey("content") and json["content"].kind == JArray:
      let contentArray = json["content"]
      var textContent: seq[string] = @[]

      for item in contentArray:
        if item.kind != JObject:
          continue

        if item.hasKey("type"):
          let contentType = item["type"].getStr("")

          case contentType:
          of "text":
            if item.hasKey("text"):
              textContent.add(item["text"].getStr(""))

          of "tool_use":
            var toolCall = ToolCall(
              id: item.getOrDefault("id").getStr(""),
              name: item.getOrDefault("name").getStr("")
            )

            # Anthropic uses "input" for arguments
            if item.hasKey("input") and item["input"].kind == JObject:
              for k, v in item["input"]:
                toolCall.arguments[k] = v

            resp.tool_calls.add(toolCall)

      if textContent.len > 0:
        var contentStr = textContent.join("\n")
        # Extract and format thinking content from reasoning models
        let (thinking, cleanContent) = extractThinkContent(contentStr)
        contentStr = formatWithThinking(thinking, cleanContent)
        if contentStr.len > 0:
          resp.content = some(contentStr)

    if json.hasKey("stop_reason"):
      resp.finish_reason = json["stop_reason"].getStr("stop")
    elif json.hasKey("stop_sequence"):
      resp.finish_reason = "stop"
    else:
      resp.finish_reason = "stop"

    # Anthropic usage format
    if json.hasKey("usage") and json["usage"].kind == JObject:
      let usage = json["usage"]
      resp.usage = UsageInfo(
        prompt_tokens: usage.getOrDefault("input_tokens").getInt(),
        completion_tokens: usage.getOrDefault("output_tokens").getInt(),
        total_tokens: usage.getOrDefault("input_tokens").getInt() +
                     usage.getOrDefault("output_tokens").getInt()
      )
  except CatchableError as e:
    warn "Adapter failed to normalize response", msg = e.msg

  return resp

# Google Gemini Adapter

type
  GeminiAdapter* = ref object of ProviderAdapter

method normalizeResponse*(a: GeminiAdapter, json: JsonNode): LLMResponse {.gcsafe, raises: [].} =
  ## Normalize Google Gemini response to internal schema
  var resp = LLMResponse()

  try:
    if json.hasKey("candidates") and json["candidates"].kind == JArray and json["candidates"].len > 0:
      let candidate = json["candidates"][0]

      if candidate.hasKey("content") and candidate["content"].kind == JObject:
        let content = candidate["content"]

        if content.hasKey("parts") and content["parts"].kind == JArray:
          var textParts: seq[string] = @[]

          for part in content["parts"]:
            if part.kind != JObject:
              continue

            if part.hasKey("text"):
              textParts.add(part["text"].getStr(""))

            # Gemini function calls
            if part.hasKey("functionCall") and part["functionCall"].kind == JObject:
              let fc = part["functionCall"]
              var toolCall = ToolCall(
                id: "gemini_call_" & $getTime(),
                name: fc.getOrDefault("name").getStr("")
              )

              if fc.hasKey("args") and fc["args"].kind == JObject:
                for k, v in fc["args"]:
                  toolCall.arguments[k] = v

              resp.tool_calls.add(toolCall)

          if textParts.len > 0:
            var contentStr = textParts.join("\n")
            # Extract and format thinking content from reasoning models
            let (thinking, cleanContent) = extractThinkContent(contentStr)
            contentStr = formatWithThinking(thinking, cleanContent)
            if contentStr.len > 0:
              resp.content = some(contentStr)

      if candidate.hasKey("finishReason"):
        resp.finish_reason = candidate["finishReason"].getStr("stop")
      else:
        resp.finish_reason = "stop"

    # Gemini usage format
    if json.hasKey("usageMetadata") and json["usageMetadata"].kind == JObject:
      let usage = json["usageMetadata"]
      resp.usage = UsageInfo(
        prompt_tokens: usage.getOrDefault("promptTokenCount").getInt(),
        completion_tokens: usage.getOrDefault("candidatesTokenCount").getInt(),
        total_tokens: usage.getOrDefault("totalTokenCount").getInt()
      )
  except CatchableError as e:
    warn "Adapter failed to normalize response", msg = e.msg

  return resp

# Adapter Factory

proc getAdapter*(provider: string): ProviderAdapter {.raises: [].} =
  ## Get the appropriate adapter for a provider
  try:
    case provider.toLowerAscii():
    of "openai", "openrouter", "groq", "vllm", "zhipu", "kimi":
      OpenAIAdapter()
    of "ollama":
      OllamaAdapter()
    of "anthropic":
      AnthropicAdapter()
    of "gemini":
      GeminiAdapter()
    else:
      # Default to OpenAI adapter for unknown providers
      OpenAIAdapter()
  except CatchableError as e:
    warn "Failed to create adapter, using default", msg = e.msg
    OpenAIAdapter()
