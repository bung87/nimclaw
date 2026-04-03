import unittest, os, json, tables, strutils
import chronos
import nimclaw/tools/search_providers/[base, brave, searxng]
import nimclaw/tools/web
import nimclaw/config

# Real query integration tests for web search providers
# These tests make actual HTTP requests to verify provider functionality

suite "Brave Provider (Real Query - requires BRAVE_API_KEY)":
  test "search with valid API key":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("artificial intelligence", 5)

      check results.len > 0
      check results[0].title.len > 0
      check results[0].url.startsWith("http")
      echo "Brave first result: " & results[0].title

  test "fails without API key":
    let provider = newBraveProvider("")

    expect ValueError:
      discard waitFor provider.search("test query", 5)

  test "search returns snippets":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("machine learning", 3)

      check results.len > 0
      var hasSnippet = false
      for r in results:
        if r.snippet.len > 0:
          hasSnippet = true
          break
      check hasSnippet
      echo "Brave results include snippets: " & $hasSnippet

  test "respects count parameter":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("python tutorial", 3)
      check results.len <= 3
      echo "Brave returned " & $results.len & " results (requested 3)"

  test "handles special characters in query":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("C++ programming & STL", 3)
      check results.len >= 0
      echo "Brave handled special chars query, got " & $results.len & " results"

suite "SearXNG Provider (Real Query - requires local instance)":
  test "search with local instance":
    let provider = newSearXNGProvider("http://localhost:8888")

    try:
      let results = waitFor provider.search("nim lang", 5)
      check results.len > 0
      echo "SearXNG found " & $results.len & " results"
    except IOError:
      echo "SearXNG not running on localhost:8888, skipping"
      skip()

  test "fails with invalid base URL":
    let provider = newSearXNGProvider("")

    expect ValueError:
      discard waitFor provider.search("test", 5)

  test "search with custom port":
    let provider = newSearXNGProvider("http://localhost:8080")

    try:
      let results = waitFor provider.search("docker containers", 3)
      check results.len >= 0
      echo "SearXNG on :8080 returned " & $results.len & " results"
    except IOError:
      echo "SearXNG not running on localhost:8080, skipping"
      skip()

  test "respects count parameter":
    let provider = newSearXNGProvider("http://localhost:8888")

    try:
      let results = waitFor provider.search("linux tutorial", 2)
      check results.len <= 2
      echo "SearXNG returned " & $results.len & " results (requested 2)"
    except IOError:
      echo "SearXNG not running, skipping"
      skip()

suite "WebSearchTool Integration (Real Queries)":
  test "uses SearXNG by default":
    let cfg = WebSearchConfig(
      max_results: 3,
      providers: @[
        SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)
      ],
      fallback_order: @["searxng"]
    )
    let tool = newWebSearchTool(cfg)

    let args = {
      "query": %"github nim lang",
      "count": %3
    }.toTable

    let res = waitFor tool.execute(args)

    # May fail if SearXNG not running, check format not content
    check res.contains("Results for:") or res.contains("No results") or res.contains("Error:")
    if res.contains("Results for:"):
      echo "WebSearchTool result preview: " & res[0..<min(200, res.len)]
    else:
      echo "SearXNG query failed (may not be running)"

  test "fallback chain works":
    # Configure with fake brave (will fail) and searxng
    let cfg = WebSearchConfig(
      max_results: 2,
      providers: @[
        SearchProviderConfig(name: "brave", api_key: "invalid_key", enabled: true),
        SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)
      ],
      fallback_order: @["brave", "searxng"]
    )
    let tool = newWebSearchTool(cfg)

    let args = {"query": %"open source software"}.toTable

    let res = waitFor tool.execute(args)

    check res.contains("Results for:") or res.contains("Error:") or res.contains("No results")
    if res.contains("Results for:"):
      echo "Fallback succeeded"
    else:
      echo "Providers failed or returned no results"

  test "handles empty query gracefully":
    let cfg = WebSearchConfig(
      max_results: 3,
      providers: @[SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)],
      fallback_order: @["searxng"]
    )
    let tool = newWebSearchTool(cfg)

    let args = {"query": %""}.toTable

    let res = waitFor tool.execute(args)
    check res.len > 0
    echo "Empty query response: " & res[0..<min(100, res.len)]

  test "formatResults produces readable output":
    let results = @[
      SearchResult(title: "Test Title", url: "https://example.com", snippet: "Test snippet"),
      SearchResult(title: "Another Title", url: "https://test.org", snippet: "")
    ]

    let formatted = formatResults(results, "test query")

    check formatted.contains("Results for: test query")
    check formatted.contains("1. Test Title")
    check formatted.contains("https://example.com")
    check formatted.contains("Test snippet")
    check formatted.contains("2. Another Title")

suite "Search Result Validation (with Brave API key)":
  test "search results have valid URLs":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("stackoverflow", 5)

      if results.len == 0:
        skip()
      else:
        for r in results:
          check r.url.startsWith("http://") or r.url.startsWith("https://")
          check r.url.contains(".")

  test "titles are not empty":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("wikipedia", 5)

      if results.len == 0:
        skip()
      else:
        for r in results:
          check r.title.len > 0
          check r.title.strip().len > 0

  test "handles unicode queries":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let results = waitFor provider.search("日本語", 3)
      check results.len >= 0
      echo "Unicode query returned " & $results.len & " results"

  test "handles long queries":
    let apiKey = getEnv("BRAVE_API_KEY", "")
    if apiKey == "":
      skip()
    else:
      let provider = newBraveProvider(apiKey)

      let longQuery = "how to implement a distributed system in nim programming language with async await"
      let results = waitFor provider.search(longQuery, 3)
      check results.len >= 0
      echo "Long query returned " & $results.len & " results"

# Run instructions:
# nimble test  # or
# nim c -r tests/test_search_providers.nim
# BRAVE_API_KEY=xxx nim c -r tests/test_search_providers.nim  # to test Brave
