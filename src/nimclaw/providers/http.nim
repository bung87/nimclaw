import std/[json, strutils, tables]
import chronos
import chronos/apps/http/httpclient
import types
import ../config as claw_config
import ../logger

const
  MAX_JSON_RESPONSE_SIZE = 10 * 1024 * 1024 # 10MB limit for JSON responses

type
  HTTPProvider* = ref object of LLMProvider
    apiKey*: string
    apiBase*: string
    provider*: string # provider type: "openai", "ollama", etc.
    session*: HttpSessionRef

proc newHTTPProvider*(apiKey, apiBase, provider: string): HTTPProvider =
  let session = HttpSessionRef.new()
  HTTPProvider(
    apiKey: apiKey,
    apiBase: apiBase,
    provider: provider,
    session: session
  )

method getDefaultModel*(p: HTTPProvider): string {.raises: [].} =
  return ""

method chat*(p: HTTPProvider, messages: seq[Message], tools: seq[ToolDefinition], model: string, options: Table[string,
    JsonNode]): Future[LLMResponse] {.async.} =
  if p.apiBase == "":
    raise newException(ValueError, "API base not configured")

  var requestBody = %*{
    "model": model,
    "messages": messages
  }

  if tools.len > 0:
    requestBody["tools"] = %tools
    requestBody["tool_choice"] = %"auto"

  if options.hasKey("max_tokens"):
    # GLM, O1, and Ollama use different parameter names or don't support max_tokens
    if p.provider in ["zhipu", "ollama"]:
      discard # Don't send max_tokens for these providers
    else:
      requestBody["max_tokens"] = options["max_tokens"]

  if options.hasKey("temperature"):
    requestBody["temperature"] = options["temperature"]

  let url = p.apiBase & "/chat/completions"
  let bodyStr = $requestBody
  echo "DEBUG REQUEST: ", bodyStr
  echo "DEBUG PROVIDER: ", p.provider

  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))
  if p.apiKey != "":
    headers.add((key: "Authorization", value: "Bearer " & p.apiKey))

  # Create and send request using chronos
  let addressRes = p.session.getAddress(url)
  if addressRes.isErr:
    raise newException(IOError, "Failed to resolve URL: " & url)
  let address = addressRes.get()

  let request = HttpClientRequestRef.new(
    p.session,
    address,
    meth = MethodPost,
    headers = headers,
    body = bodyStr.toOpenArrayByte(0, bodyStr.len - 1)
  )

  let response = await request.send()
  let bodyBytes = await response.getBodyBytes()
  let bodyText = cast[string](bodyBytes)

  if response.status < 200 or response.status >= 300:
    echo "DEBUG ERROR: ", bodyText
    raise newException(IOError, "API error ($1): $2".format($response.status, bodyText))

  # Validate JSON response size before parsing
  if bodyBytes.len > MAX_JSON_RESPONSE_SIZE:
    raise newException(IOError, "JSON response too large ($1 bytes, max $2)".format($bodyBytes.len,
        $MAX_JSON_RESPONSE_SIZE))

  let jsonResp = parseJson(bodyText)
  debug("LLM response received", topic = "http", body = bodyText[0..<min(500, bodyText.len)])

  var llmResp = LLMResponse()
  if jsonResp.hasKey("choices") and jsonResp["choices"].len > 0:
    let choice = jsonResp["choices"][0]
    let msg = choice["message"]
    if msg.hasKey("content") and msg["content"].kind != JNull:
      llmResp.content = msg["content"].getStr()

    # Handle tool_calls from OpenAI-compatible APIs
    if msg.hasKey("tool_calls"):
      for tc in msg["tool_calls"]:
        var toolCall = ToolCall(
          id: tc.getOrDefault("id").getStr(""),
          `type`: tc.getOrDefault("type").getStr("function")
        )
        # Standard OpenAI format: tool_calls[].function.name
        if tc.hasKey("function"):
          let fn = tc["function"]
          toolCall.name = fn.getOrDefault("name").getStr("")
          if fn.hasKey("arguments"):
            let argsStr = fn["arguments"].getStr()
            try:
              let argsJson = parseJson(argsStr)
              for k, v in argsJson.fields:
                toolCall.arguments[k] = v
            except:
              toolCall.arguments["raw"] = %argsStr
        # Some providers may put name directly in tool_calls[]
        elif tc.hasKey("name"):
          toolCall.name = tc["name"].getStr("")
          if tc.hasKey("arguments"):
            let argsStr = tc["arguments"].getStr()
            try:
              let argsJson = parseJson(argsStr)
              for k, v in argsJson.fields:
                toolCall.arguments[k] = v
            except:
              toolCall.arguments["raw"] = %argsStr
        if toolCall.name != "":
          llmResp.tool_calls.add(toolCall)
          debug("Parsed tool call", topic = "http", name = toolCall.name, id = toolCall.id)
        else:
          debug("Skipping tool call with empty name", topic = "http", tc = $tc)

    llmResp.finish_reason = choice.getOrDefault("finish_reason").getStr("stop")

  if jsonResp.hasKey("usage"):
    let usage = jsonResp["usage"]
    llmResp.usage = UsageInfo(
      prompt_tokens: usage.getOrDefault("prompt_tokens").getInt(),
      completion_tokens: usage.getOrDefault("completion_tokens").getInt(),
      total_tokens: usage.getOrDefault("total_tokens").getInt()
    )

  return llmResp

proc createProvider*(cfg: Config): LLMProvider =
  let provider = cfg.agents.defaults.provider
  var apiKey, apiBase: string

  case provider:
  of "openrouter":
    apiKey = cfg.providers.openrouter.api_key
    apiBase = if cfg.providers.openrouter.api_base != "": cfg.providers.openrouter.api_base else: "https://openrouter.ai/api/v1"
  of "anthropic":
    apiKey = cfg.providers.anthropic.api_key
    apiBase = if cfg.providers.anthropic.api_base != "": cfg.providers.anthropic.api_base else: "https://api.anthropic.com/v1"
  of "openai":
    apiKey = cfg.providers.openai.api_key
    apiBase = if cfg.providers.openai.api_base != "": cfg.providers.openai.api_base else: "https://api.openai.com/v1"
  of "gemini":
    apiKey = cfg.providers.gemini.api_key
    apiBase = if cfg.providers.gemini.api_base != "": cfg.providers.gemini.api_base else: "https://generativelanguage.googleapis.com/v1beta"
  of "zhipu":
    apiKey = cfg.providers.zhipu.api_key
    apiBase = if cfg.providers.zhipu.api_base != "": cfg.providers.zhipu.api_base else: "https://open.bigmodel.cn/api/paas/v4"
  of "groq":
    apiKey = cfg.providers.groq.api_key
    apiBase = if cfg.providers.groq.api_base != "": cfg.providers.groq.api_base else: "https://api.groq.com/openai/v1"
  of "vllm":
    apiKey = cfg.providers.vllm.api_key
    apiBase = cfg.providers.vllm.api_base
  of "kimi":
    apiKey = cfg.providers.kimi.api_key
    apiBase = if cfg.providers.kimi.api_base != "": cfg.providers.kimi.api_base else: "https://api.moonshot.cn/v1"
  of "ollama":
    apiKey = cfg.providers.ollama.api_key
    apiBase = if cfg.providers.ollama.api_base != "": cfg.providers.ollama.api_base else: "http://localhost:11434/v1"
  else:
    raise newException(ValueError, "unknown provider: " & provider)

  if apiKey == "" and provider != "ollama":
    raise newException(ValueError, "no API key configured for provider: " & provider)

  if apiBase == "":
    raise newException(ValueError, "no API base configured for provider: " & provider)

  return newHTTPProvider(apiKey, apiBase, provider)
