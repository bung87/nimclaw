import std/[tables, json, options, strutils, times]
import types

# Helper Functions

proc safeParseJson*(s: string): JsonNode {.raises: [].} =
  ## Safely parse JSON, return empty object on error
  try:
    return parseJson(s)
  except:
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
  except:
    discard
  return result

proc tryParseToolCallFromContent*(content: string): seq[ToolCall] {.raises: [].} =
  ## Ollama-specific: Some models output tool calls as JSON in content field
  ## instead of using the proper tool_calls array. This parses that as a fallback.
  var calls: seq[ToolCall] = @[]
  let trimmed = content.strip()

  if trimmed.len == 0:
    return calls

  # Only try if content starts with '{' (JSON object)
  if trimmed[0] != '{':
    return calls

  # Check for newlines - if present, likely mixed text+JSON, skip
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

        # Extract content
        var hasContent = false
        var contentStr = ""
        if msg.hasKey("content") and msg["content"].kind != JNull:
          contentStr = msg["content"].getStr("")
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
  except:
    # If anything goes wrong, return empty response
    discard

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
      # Extract content
      if msg.hasKey("content"):
        let content = msg["content"].getStr("")
        if content.len > 0:
          resp.content = some(content)

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
          if argsNode.kind == JObject:
            for k, v in argsNode:
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
  except:
    # If anything goes wrong, return empty response
    discard

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
        resp.content = some(textContent.join("\n"))

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
  except:
    # If anything goes wrong, return empty response
    discard

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
            resp.content = some(textParts.join("\n"))

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
  except:
    # If anything goes wrong, return empty response
    discard

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
  except:
    OpenAIAdapter()
