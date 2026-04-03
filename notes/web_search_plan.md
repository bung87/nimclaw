# Web Search Evolution Plan for Nimclaw

## 1. Current State

Nimclaw's `web_search` tool (`src/nimclaw/tools/web.nim`) supports multiple providers with fallback:

- **Brave Search** — requires `BRAVE_API_KEY`, official API
- **SearXNG** — self-hosted, no API key needed, truly free
- Fallback chain tries providers in order until one succeeds

## 2. Supported Providers

### 2.1 SearXNG (Self-Hosted Privacy-First) — DEFAULT

**Used by:** OpenClaw, SearXNG MCP servers, `langchain-community`.

- **Cost:** Free, open-source (AGPL), self-hosted.
- **How it works:** Metasearch engine that queries 70+ sources (Google, Bing, DDG, Wikipedia, Brave, etc.) and returns unified JSON via `GET /search?q=...&format=json`.
- **Limitations:**
  - Requires running a Docker container or public instance.
  - Public instances can be slow or rate-limited.
- **Why it matters:** Full privacy, no third-party API dependency, excellent for local/home-server deployments.
- **Why it's the default:** Unlike scraping-based solutions, SearXNG is designed for API access and won't break due to bot detection.

### 2.2 Brave Search (Official API)

**Used by:** OpenClaw, `cli-web-search`, many agent frameworks.

- **Cost:** Free tier (1,000 queries/month), then $5/1,000 queries.
- **How it works:** Official REST API with API key authentication.
- **Why it matters:** Reliable, official API with SLA, good for production use.

### 2.3 Tavily (AI-Optimized Premium) — FUTURE

**Used by:** OpenClaw, `web-search-pro`, many production agents.

- **Cost:** 1,000 free searches/month, then ~$0.01/query.
- **How it works:** Proprietary index optimized for LLM consumption. Returns structured answers, relevance scores, and follow-up suggestions.
- **Why it matters:** Best quality for agents that need grounded, citation-rich answers.

## 3. Why DuckDuckGo Was Removed

DuckDuckGo was initially considered as a "free" alternative, but was removed because:

1. **No official API** — DuckDuckGo is designed for human browsing, not programmatic access
2. **Aggressive bot detection** — Returns HTTP 202/CAPTCHAs for automated requests
3. **Unreliable for agents** — Rate limits based on IP, blocks datacenter/cloud IPs
4. **Not truly "free" for automation** — While browsing is free, scraping violates terms and breaks frequently

For truly free search without API keys, **self-hosted SearXNG** is the recommended solution.

## 4. Provider Abstraction

```nim
type
  SearchResult* = object
    title*: string
    url*: string
    snippet*: string

  SearchProvider* = ref object of RootObj

method search*(p: SearchProvider, query: string, count: int): Future[seq[SearchResult]] {.base, async.} =
  discard
```

**Concrete providers:**

| Provider | Needs Key? | Notes |
|----------|------------|-------|
| `BraveProvider` | Yes | Official API, reliable for production |
| `SearXNGProvider` | No | Self-hosted, truly free, designed for API access |

## 5. Configuration

```nim
type
  SearchProviderConfig* = object
    name*: string            # "brave", "searxng"
    api_key*: string
    base_url*: string        # for searxng
    enabled*: bool

  WebSearchConfig* = object
    max_results*: int
    timeout_seconds*: int
    providers*: seq[SearchProviderConfig]
    fallback_order*: seq[string]
```

**Default configuration:**

```nim
providers: @[
  SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)
],
fallback_order: @["searxng"]
```

**Backward-compatible migration:**

```nim
# If old api_key is present, auto-migrate to Brave provider
if cfg.tools.web.search.api_key != "" and cfg.tools.web.search.providers.len == 0:
  cfg.tools.web.search.providers.add(SearchProviderConfig(
    name: "brave", api_key: cfg.tools.web.search.api_key, enabled: true
  ))
  cfg.tools.web.search.fallback_order = @["brave", "searxng"]
```

## 6. Execution Logic: Fallback Chain

1. Build map of enabled providers from config
2. Iterate through `fallback_order`:
   - Instantiate provider adapter
   - Call `await provider.search(query, count)`
   - On success: return formatted results
   - On **retryable error** (timeout, 429, 5xx): continue to next provider
   - On **permanent error** (401, 403, 400): break and return error
3. If all providers fail, return concatenated error report

## 7. File Structure

```
src/nimclaw/
├── tools/
│   ├── web.nim                    # WebSearchTool with fallback chain
│   └── search_providers/
│       ├── base.nim               # SearchProvider interface + SearchResult
│       ├── brave.nim              # Brave Search adapter
│       └── searxng.nim            # SearXNG JSON API adapter
├── config.nim                     # Extended WebSearchConfig
└── tests/
    └── test_search_providers.nim  # Integration tests
```

## 8. Setting Up SearXNG (Self-Hosted)

Quick Docker setup:

```bash
mkdir -p ~/searxng && cd ~/searxng

cat > docker-compose.yml << 'EOF'
services:
  searxng:
    image: searxng/searxng:latest
    ports:
      - "8888:8080"
    volumes:
      - ./searxng:/etc/searxng:rw
    environment:
      - SEARXNG_BASE_URL=http://localhost:8888/
EOF

docker compose up -d
```

Then configure Nimclaw to use it (or it will use `http://localhost:8888` by default).

## 9. Usage Examples

### Default (SearXNG)
```
User: "Search for the latest Nim release"
Agent: [tries SearXNG on localhost:8888]
Results for: latest Nim release
1. Nim 2.2.0 released
   https://nim-lang.org/blog/2024/10/02/nim-220-released.html
```

### With Brave API key
```bash
export BRAVE_API_KEY=your_key
```
Config auto-migrates to: `fallback_order = @["brave", "searxng"]`

### With custom SearXNG instance
```json
{
  "tools": {
    "web": {
      "search": {
        "providers": [
          {"name": "searxng", "base_url": "https://search.example.com", "enabled": true}
        ],
        "fallback_order": ["searxng"]
      }
    }
  }
}
```

## 10. References

- SearXNG JSON API docs: https://docs.searxng.org/dev/search_api.html
- SearXNG Docker setup: https://github.com/searxng/searxng-docker
- Brave Search API: https://api.search.brave.com/
- Multi-provider fallback pattern (LobeHub): https://lobehub.com/mcp/taka499-mcp-web-search
