import chronos
import puppy
import std/[json, strutils, uri]
import base

const userAgent = "Mozilla/5.0 (compatible; nimclaw/1.0)"

type
  SearXNGProvider* = ref object of SearchProvider
    baseUrl*: string

proc newSearXNGProvider*(baseUrl: string): SearXNGProvider =
  var url = baseUrl
  if url.endsWith("/"): url = url[0 ..< ^1]
  SearXNGProvider(baseUrl: url)

method name*(p: SearXNGProvider): string = "searxng"

method search*(p: SearXNGProvider, query: string, count: int): Future[seq[SearchResult]] {.async.} =
  if p.baseUrl == "":
    raise newException(ValueError, "SearXNG base_url not configured")

  let searchURL = p.baseUrl & "/search?q=" & encodeUrl(query) & "&format=json"
  let headers = @[(
    "User-Agent", userAgent
  ), (
    "Accept", "application/json"
  )]

  let res = puppy.get(searchURL, headers)
  if res.code != 200:
    raise newException(IOError, "HTTP $1".format(res.code))

  let jsonResp = parseJson(res.body)

  if not jsonResp.hasKey("results"):
    return @[]

  let results = jsonResp["results"]
  var outResults: seq[SearchResult] = @[]
  for i in 0 ..< min(results.len, count):
    let item = results[i]
    outResults.add(SearchResult(
      title: item.getOrDefault("title").getStr(""),
      url: item.getOrDefault("url").getStr(""),
      snippet: item.getOrDefault("content").getStr("")
    ))
  return outResults
