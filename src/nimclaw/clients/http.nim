import std/[json, strutils, tables]
import chronos
import chronos/apps/http/httpclient
import ../providers/types
import ../providers/adapters
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

proc newHTTPProvider*(apiKey, apiBase, provider: string): HTTPProvider =
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

  var requestBody = %*{
    "model": model,
    "messages": messagesToJson(messages)
  }

  if tools.len > 0:
    requestBody["tools"] = %tools
    requestBody["tool_choice"] = %"auto"

  if options.hasKey("max_tokens"):
    if p.provider notin ["zhipu", "ollama"]:
      requestBody["max_tokens"] = options["max_tokens"]

  if options.hasKey("temperature"):
    requestBody["temperature"] = options["temperature"]

  let url = p.apiBase & "/chat/completions"
  let bodyStr = $requestBody

  var headers: seq[HttpHeaderTuple] = @[]
  headers.add((key: "Content-Type", value: "application/json"))
  if p.apiKey != "":
    headers.add((key: "Authorization", value: "Bearer " & p.apiKey))

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

  var llmResp = p.adapter.normalizeResponse(jsonResp)
  return llmResp
