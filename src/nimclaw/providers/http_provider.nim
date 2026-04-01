import std/[json, strutils, tables]
import chronos
import chronos/apps/http/httpclient
import types
import adapters
import ../config as claw_config
import ../logger

const
  MAX_JSON_RESPONSE_SIZE = 10 * 1024 * 1024 # 10MB limit for JSON responses

type
  HTTPProvider* = ref object of LLMProvider
    apiKey*: string
    apiBase*: string
    provider*: string
    session*: HttpSessionRef
    adapter*: ProviderAdapter

# ==============================================================================
# HTTP Provider Implementation
# ==============================================================================

proc newHTTPProvider*(apiKey, apiBase, provider: string): HTTPProvider =
  ## Create a new HTTP provider with appropriate adapter
  let session = HttpSessionRef.new()
  let adapter = getAdapter(provider)

  HTTPProvider(
    apiKey: apiKey,
    apiBase: apiBase,
    provider: provider,
    session: session,
    adapter: adapter
  )

method getDefaultModel*(p: HTTPProvider): string {.raises: [].} =
  return ""

method chat*(p: HTTPProvider,
             messages: seq[Message],
             tools: seq[ToolDefinition],
             model: string,
             options: Table[string, JsonNode]): Future[LLMResponse] {.async.} =

  if p.apiBase == "":
    raise newException(ValueError, "API base not configured")

  # Build request body using normalized messages
  var requestBody = %*{
    "model": model,
    "messages": messagesToJson(messages)
  }

  # Add tools if provided
  if tools.len > 0:
    requestBody["tools"] = %tools
    requestBody["tool_choice"] = %"auto"

  # Add optional parameters
  if options.hasKey("max_tokens"):
    if p.provider notin ["zhipu", "ollama"]:
      requestBody["max_tokens"] = options["max_tokens"]

  if options.hasKey("temperature"):
    requestBody["temperature"] = options["temperature"]

  let url = p.apiBase & "/chat/completions"
  let bodyStr = $requestBody

  # Build headers
  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))
  if p.apiKey != "":
    headers.add((key: "Authorization", value: "Bearer " & p.apiKey))

  # Send request
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
    raise newException(IOError, "API error ($1): $2".format($response.status, bodyText))

  if bodyBytes.len > MAX_JSON_RESPONSE_SIZE:
    raise newException(IOError,
      "JSON response too large ($1 bytes, max $2)".format($bodyBytes.len, $MAX_JSON_RESPONSE_SIZE))

  let jsonResp = parseJson(bodyText)
  debug("LLM response received", topic = "http",
        body = bodyText[0..<min(500, bodyText.len)])

  # Use adapter to normalize response
  var llmResp = p.adapter.normalizeResponse(jsonResp)

  return llmResp

# ==============================================================================
# Provider Factory
# ==============================================================================

proc createProvider*(cfg: Config): LLMProvider =
  ## Factory function to create appropriate provider based on config
  let provider = cfg.agents.defaults.provider
  var apiKey, apiBase: string

  case provider:
  of "openrouter":
    apiKey = cfg.providers.openrouter.api_key
    apiBase = if cfg.providers.openrouter.api_base != "":
      cfg.providers.openrouter.api_base
    else:
      "https://openrouter.ai/api/v1"

  of "anthropic":
    apiKey = cfg.providers.anthropic.api_key
    apiBase = if cfg.providers.anthropic.api_base != "":
      cfg.providers.anthropic.api_base
    else:
      "https://api.anthropic.com/v1"

  of "openai":
    apiKey = cfg.providers.openai.api_key
    apiBase = if cfg.providers.openai.api_base != "":
      cfg.providers.openai.api_base
    else:
      "https://api.openai.com/v1"

  of "gemini":
    apiKey = cfg.providers.gemini.api_key
    apiBase = if cfg.providers.gemini.api_base != "":
      cfg.providers.gemini.api_base
    else:
      "https://generativelanguage.googleapis.com/v1beta"

  of "zhipu":
    apiKey = cfg.providers.zhipu.api_key
    apiBase = if cfg.providers.zhipu.api_base != "":
      cfg.providers.zhipu.api_base
    else:
      "https://open.bigmodel.cn/api/paas/v4"

  of "groq":
    apiKey = cfg.providers.groq.api_key
    apiBase = if cfg.providers.groq.api_base != "":
      cfg.providers.groq.api_base
    else:
      "https://api.groq.com/openai/v1"

  of "vllm":
    apiKey = cfg.providers.vllm.api_key
    apiBase = cfg.providers.vllm.api_base

  of "kimi":
    apiKey = cfg.providers.kimi.api_key
    apiBase = if cfg.providers.kimi.api_base != "":
      cfg.providers.kimi.api_base
    else:
      "https://api.moonshot.cn/v1"

  of "ollama":
    apiKey = cfg.providers.ollama.api_key
    apiBase = if cfg.providers.ollama.api_base != "":
      cfg.providers.ollama.api_base
    else:
      "http://localhost:11434/v1"

  else:
    raise newException(ValueError, "unknown provider: " & provider)

  if apiKey == "" and provider != "ollama":
    raise newException(ValueError, "no API key configured for provider: " & provider)

  if apiBase == "":
    raise newException(ValueError, "no API base configured for provider: " & provider)

  return newHTTPProvider(apiKey, apiBase, provider)
