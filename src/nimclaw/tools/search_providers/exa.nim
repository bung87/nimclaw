import chronos
import puppy
import std/[json, strutils]
import base

const
  exaApiUrl = "https://api.exa.ai/search"
  userAgent = "Mozilla/5.0 (compatible; nimclaw/1.0)"

type
  ExaProvider* = ref object of SearchProvider
    apiKey*: string
    searchType*: string # "auto", "neural", "keyword"
    includeSummary*: bool
    includeHighlights*: bool

proc newExaProvider*(apiKey: string, searchType = "auto", includeSummary = false,
    includeHighlights = false): ExaProvider =
  ExaProvider(
    apiKey: apiKey,
    searchType: searchType,
    includeSummary: includeSummary,
    includeHighlights: includeHighlights
  )

method name*(p: ExaProvider): string = "exa"

method search*(p: ExaProvider, query: string, count: int): Future[seq[SearchResult]] {.async.} =
  if p.apiKey == "":
    raise newException(ValueError, "EXA_API_KEY not configured")

  # Build request body
  var reqBody = %*{
    "query": query,
    "numResults": count,
    "type": p.searchType
  }

  # Add optional content flags
  if p.includeHighlights:
    reqBody["includeHighlights"] = %true
  if p.includeSummary:
    reqBody["includeSummary"] = %true

  # Always include text for snippet
  reqBody["includeText"] = %true

  let headers = @[
    ("Content-Type", "application/json"),
    ("Authorization", "Bearer " & p.apiKey),
    ("User-Agent", userAgent)
  ]

  let res = puppy.post(exaApiUrl, headers, $reqBody)
  if res.code != 200:
    raise newException(IOError, "HTTP $1: $2".format(res.code, res.body))

  let jsonResp = parseJson(res.body)

  if not jsonResp.hasKey("results"):
    return @[]

  let results = jsonResp["results"]
  var outResults: seq[SearchResult] = @[]

  for i in 0 ..< min(results.len, count):
    let item = results[i]

    # Build snippet from available fields
    var snippetParts: seq[string] = @[]

    # Use summary if available and enabled
    if p.includeSummary and item.hasKey("summary"):
      let summary = item["summary"].getStr("")
      if summary.len > 0:
        snippetParts.add(summary)

    # Fall back to text field
    if snippetParts.len == 0 and item.hasKey("text"):
      let text = item["text"].getStr("")
      if text.len > 0:
        # Truncate long text
        let maxLen = 300
        if text.len > maxLen:
          snippetParts.add(text[0 ..< maxLen] & "...")
        else:
          snippetParts.add(text)

    # Use highlights if available and enabled
    if p.includeHighlights and item.hasKey("highlights"):
      let highlights = item["highlights"]
      if highlights.len > 0:
        for h in highlights:
          let hl = h.getStr("")
          if hl.len > 0:
            snippetParts.add("• " & hl)
            break # Just add first highlight

    let snippet = snippetParts.join(" ")

    outResults.add(SearchResult(
      title: item.getOrDefault("title").getStr(""),
      url: item.getOrDefault("url").getStr(""),
      snippet: snippet
    ))

  return outResults
