import ../config
import ../clients/http
import types

proc createProvider*(cfg: Config): LLMProvider =
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
