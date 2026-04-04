# GLM Search Research Notes

## Overview

GLM Search is Zhipu AI's (智谱 AI) web search service integrated into their GLM model API. Zhipu AI is a Chinese AI company and OpenAI competitor.

## Pricing

| Tier | Price | Details |
|------|-------|---------|
| **GLM-4.5-flash** | **FREE** | $0/1M tokens, 128K context |
| **New users** | **~25M tokens free** | Valid for 1 month |
| **GLM-4.7** | $0.60/1M input, $2.20/1M output | Full model with search |
| **Coding Plan** | $3/month starter | 120 prompts/month |

## Account Requirement

**GLM-4.5-flash requires a user account**, even though it's marketed as "free":

1. Create account on Z.ai (Zhipu AI platform)
2. Add at least $5 credit to account (billing info required even for free tier)
3. Generate API key from dashboard

**Not** like DuckDuckGo (truly no signup). It's "free tier with signup."

## API Format

```json
{
  "model": "glm-4.5-flash",
  "messages": [...],
  "tools": [{"type": "web_search"}]
}
```

## Alternatives Without Signup

| Option | Signup Required | Notes |
|--------|----------------|-------|
| **DuckDuckGo** | No | Scraping-based, truly free |
| **SearXNG** | No | Self-hosted |
| **Hugging Face Demo** | No | Web UI only, not API |
| **OpenRouter** | Yes | But gives free credits |
| **Local deployment** | No | Requires 8x H100 GPUs |

## Nimclaw Integration Assessment

**Verdict:** Good addition for users who already have Zhipu accounts, but cannot be a "zero-config" fallback like DuckDuckGo due to signup requirement.

### Current Nimclaw Search Providers
- Brave (API key required)
- SearXNG (self-hosted, no key)

### Missing Providers (compared to PicoClaw)
- DuckDuckGo (truly free, no signup)
- Baidu Search (China-optimized, API key)
- Tavily (AI-optimized, API key)
- Perplexity (AI-powered, API key)
- GLM Search (free but signup required)

## Key Takeaways

1. GLM-4.5-flash is **free** but **not anonymous**
2. Best for: Chinese content search (China-optimized)
3. Not suitable as: Default/no-config search provider
4. Recommended priority for implementation: After DuckDuckGo, before Tavily/Perplexity

## References

- Zhipu AI: https://z.ai
- GLM-4.5 API Docs: https://open.bigmodel.cn/dev/howuse/glm-4.5
- Pricing: https://open.bigmodel.cn/pricing
