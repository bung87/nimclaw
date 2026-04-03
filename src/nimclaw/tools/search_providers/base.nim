import chronos
import std/strutils

type
  SearchResult* = object
    title*: string
    url*: string
    snippet*: string

  SearchProvider* = ref object of RootObj

method name*(p: SearchProvider): string {.base.} = ""

method search*(p: SearchProvider, query: string, count: int): Future[seq[SearchResult]] {.base, async.} =
  return @[]

proc formatResults*(results: seq[SearchResult], query: string): string =
  if results.len == 0:
    return "No results for: " & query
  var lines: seq[string] = @["Results for: " & query]
  for i, r in results:
    lines.add("$1. $2\n   $3".format(i + 1, r.title, r.url))
    if r.snippet.len > 0:
      lines.add("   " & r.snippet)
  return lines.join("\n")
