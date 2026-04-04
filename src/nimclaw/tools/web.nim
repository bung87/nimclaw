import chronos
import puppy
import std/[json, tables, strutils, uri]
import pkg/regex except re
import types
import search_providers/[base, brave, searxng, exa]
import ../config

type
  WebSearchTool* = ref object of Tool
    cfg*: WebSearchConfig

proc newWebSearchTool*(cfg: WebSearchConfig): WebSearchTool =
  WebSearchTool(cfg: cfg)

method name*(t: WebSearchTool): string = "web_search"
method description*(t: WebSearchTool): string = "Search the web for current information. Returns titles, URLs, and snippets from search results."
method parameters*(t: WebSearchTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "query": {
        "type": "string",
        "description": "Search query"
    },
    "count": {
      "type": "integer",
      "description": "Number of results (1-10)",
      "minimum": 1,
      "maximum": 10
    }
  },
    "required": %["query"]
  }.toTable

proc buildProviders(cfg: WebSearchConfig): Table[string, SearchProvider] =
  result = initTable[string, SearchProvider]()
  for pc in cfg.providers:
    if not pc.enabled: continue
    case pc.name.toLowerAscii():
    of "brave":
      result[pc.name] = newBraveProvider(pc.api_key)
    of "searxng":
      result[pc.name] = newSearXNGProvider(pc.base_url)
    of "exa":
      result[pc.name] = newExaProvider(pc.api_key)
    else:
      discard

method execute*(t: WebSearchTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("query"): return "Error: query is required"
  let query = args["query"].getStr()
  var count = t.cfg.max_results
  if count <= 0 or count > 10: count = 5
  if args.hasKey("count"):
    let c = args["count"].getInt()
    if c > 0 and c <= 10: count = c

  let providers = buildProviders(t.cfg)
  if providers.len == 0:
    return "Error: no search providers configured"

  var order = t.cfg.fallback_order
  if order.len == 0:
    for k in providers.keys: order.add(k)

  var lastError = ""
  for providerName in order:
    if not providers.hasKey(providerName): continue
    let provider = providers[providerName]
    try:
      let results = await provider.search(query, count)
      return formatResults(results, query)
    except CatchableError as e:
      let msg = e.msg
      lastError = "$1: $2".format(providerName, msg)
      if msg.contains("not configured") or msg.contains("401") or msg.contains("403") or msg.contains("bad request"):
        return "Error: " & lastError
      continue

  return "Error: all search providers failed. Last error: " & lastError

type
  WebFetchTool* = ref object of Tool
    maxChars*: int

proc newWebFetchTool*(maxChars: int): WebFetchTool =
  let count = if maxChars <= 0: 50000 else: maxChars
  WebFetchTool(maxChars: count)

method name*(t: WebFetchTool): string = "web_fetch"
method description*(t: WebFetchTool): string = "Fetch a URL and extract readable content (HTML to text). Use this to get weather info, news, articles, or any web content."
method parameters*(t: WebFetchTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "url": {
        "type": "string",
        "description": "URL to fetch"
    },
    "maxChars": {
      "type": "integer",
      "description": "Maximum characters to extract",
      "minimum": 100
    }
  },
    "required": %["url"]
  }.toTable

proc extractText(html: string): string =
  var content = html
  content = content.replace(re2("(?s)<script[\\s\\S]*?<\\/script>"), "")
  content = content.replace(re2("(?s)<style[\\s\\S]*?<\\/style>"), "")
  content = content.replace(re2("<[^>]+>"), "")
  content = content.replace(re2("\\s+"), " ")
  return content.strip()

method execute*(t: WebFetchTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("url"): return "Error: url is required"
  let urlStr = args["url"].getStr()

  let u = parseUri(urlStr)
  if u.scheme != "http" and u.scheme != "https":
    return "Error: only http/https URLs are allowed"

  var maxChars = t.maxChars
  if args.hasKey("maxChars"):
    let mc = args["maxChars"].getInt()
    if mc > 100: maxChars = mc

  const userAgent = "Mozilla/5.0 (compatible; nimclaw/1.0)"
  let headers = @[("User-Agent", userAgent)]

  try:
    let res = puppy.get(urlStr, headers)
    let body = res.body
    let status = res.code

    var contentType = ""
    for (k, v) in res.headers:
      if k.toLowerAscii == "content-type":
        contentType = v
        break

    var text = ""
    var extractor = ""

    if contentType.contains("application/json"):
      text = body
      extractor = "json"
    elif contentType.contains("text/html") or body.startsWith("<!DOCTYPE") or body.toLowerAscii.startsWith("<html"):
      text = extractText(body)
      extractor = "text"
    else:
      text = body
      extractor = "raw"

    let truncated = text.len > maxChars
    if truncated:
      text = text[0 ..< maxChars]

    let resObj = %*{
      "url": urlStr,
      "status": $status,
      "extractor": extractor,
      "truncated": truncated,
      "length": text.len,
      "text": text
    }
    return resObj.pretty()
  except CatchableError as e:
    return "Error: fetch failed: " & e.msg
