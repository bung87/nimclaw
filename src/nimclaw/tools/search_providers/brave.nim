import chronos
import puppy
import std/[json, strutils, uri]
import base

const userAgent = "Mozilla/5.0 (compatible; nimclaw/1.0)"

type
  BraveProvider* = ref object of SearchProvider
    apiKey*: string

proc newBraveProvider*(apiKey: string): BraveProvider =
  BraveProvider(apiKey: apiKey)

method name*(p: BraveProvider): string = "brave"

method search*(p: BraveProvider, query: string, count: int): Future[seq[SearchResult]] {.async.} =
  if p.apiKey == "":
    raise newException(ValueError, "BRAVE_API_KEY not configured")

  let searchURL = "https://api.search.brave.com/res/v1/web/search?q=$1&count=$2".format(encodeUrl(query), count)
  let headers = @[(
    "X-Subscription-Token", p.apiKey
  ), (
    "User-Agent", userAgent
  ), (
    "Accept", "application/json"
  )]

  let res = puppy.get(searchURL, headers)
  if res.code != 200:
    raise newException(IOError, "HTTP $1: $2".format(res.code, res.body))

  let jsonResp = parseJson(res.body)

  if not jsonResp.hasKey("web") or not jsonResp["web"].hasKey("results"):
    return @[]

  let results = jsonResp["web"]["results"]
  var outResults: seq[SearchResult] = @[]
  for i in 0 ..< min(results.len, count):
    let item = results[i]
    outResults.add(SearchResult(
      title: item["title"].getStr(""),
      url: item["url"].getStr(""),
      snippet: if item.hasKey("description"): item["description"].getStr("") else: ""
    ))
  return outResults
