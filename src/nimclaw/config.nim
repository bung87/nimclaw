import std/[os, strutils]
import jsony

type
  AgentDefaults* = object
    workspace*: string
    model*: string
    provider*: string # explicit provider: "openai", "anthropic", "ollama", etc.
    max_tokens*: int
    temperature*: float64
    max_tool_iterations*: int

  AgentsConfig* = object
    defaults*: AgentDefaults

  WhatsAppConfig* = object
    enabled*: bool
    bridge_url*: string
    allow_from*: seq[string]

  TelegramConfig* = object
    enabled*: bool
    token*: string
    allow_from*: seq[string]

  FeishuConfig* = object
    enabled*: bool
    app_id*: string
    app_secret*: string
    encrypt_key*: string
    verification_token*: string
    allow_from*: seq[string]

  DiscordConfig* = object
    enabled*: bool
    token*: string
    allow_from*: seq[string]

  MaixCamConfig* = object
    enabled*: bool
    host*: string
    port*: int
    allow_from*: seq[string]

  QQConfig* = object
    enabled*: bool
    app_id*: string
    app_secret*: string
    allow_from*: seq[string]

  DingTalkConfig* = object
    enabled*: bool
    client_id*: string
    client_secret*: string
    allow_from*: seq[string]

  ChannelsConfig* = object
    whatsapp*: WhatsAppConfig
    telegram*: TelegramConfig
    feishu*: FeishuConfig
    discord*: DiscordConfig
    maixcam*: MaixCamConfig
    qq*: QQConfig
    dingtalk*: DingTalkConfig

  ProviderConfig* = object
    api_key*: string
    api_base*: string

  ProvidersConfig* = object
    anthropic*: ProviderConfig
    openai*: ProviderConfig
    openrouter*: ProviderConfig
    groq*: ProviderConfig
    zhipu*: ProviderConfig
    vllm*: ProviderConfig
    gemini*: ProviderConfig
    kimi*: ProviderConfig
    ollama*: ProviderConfig

  GatewayConfig* = object
    host*: string
    port*: int

  SearchProviderConfig* = object
    name*: string
    api_key*: string
    base_url*: string
    enabled*: bool

  WebSearchConfig* = object
    api_key*: string
    max_results*: int
    timeout_seconds*: int
    providers*: seq[SearchProviderConfig]
    fallback_order*: seq[string]

  WebToolsConfig* = object
    search*: WebSearchConfig

  ToolsConfig* = object
    web*: WebToolsConfig

  ContextStrategy* = enum
    csFullHistory  # Keep all messages until token limit
    csLastNTurns   # Keep only last N turns
    csSummarizeOld # Summarize older turns

  ContextStrategyConfig* = object
    strategy*: ContextStrategy
    maxTurns*: int       # max turns before summarizing
    keepLastNTurns*: int # verbatim turns to preserve
    maxTokens*: int      # token budget

  MemoryConfig* = object
    enabled*: bool
    maxFacts*: int
    extractFacts*: bool # auto-extract facts after each turn

  Config* = object
    agents*: AgentsConfig
    channels*: ChannelsConfig
    providers*: ProvidersConfig
    gateway*: GatewayConfig
    tools*: ToolsConfig
    context_strategy*: ContextStrategyConfig
    memory*: MemoryConfig

proc expandHome*(path: string): string =
  if path == "": return path
  if path[0] == '~':
    let home = getHomeDir()
    if path.len > 1 and path[1] == '/':
      return home / path[2..^1]
    return home
  return path

proc defaultConfig*(): Config =
  result = Config(
    agents: AgentsConfig(
      defaults: AgentDefaults(
        workspace: "~/.nimclaw/workspace",
        model: "glm-4.7",
        provider: "zhipu",
        max_tokens: 8192,
        temperature: 0.7,
        max_tool_iterations: 20
    )
  ),
    channels: ChannelsConfig(
      whatsapp: WhatsAppConfig(enabled: false, bridge_url: "ws://localhost:3001"),
      telegram: TelegramConfig(enabled: false),
      feishu: FeishuConfig(enabled: false),
      discord: DiscordConfig(enabled: false),
      maixcam: MaixCamConfig(enabled: false, host: "0.0.0.0", port: 18790),
      qq: QQConfig(enabled: false),
      dingtalk: DingTalkConfig(enabled: false)
    ),
    gateway: GatewayConfig(host: "0.0.0.0", port: 18790),
    tools: ToolsConfig(
      web: WebToolsConfig(
        search: WebSearchConfig(
          max_results: 5,
          timeout_seconds: 30,
          providers: @[
            SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)
      ],
      fallback_order: @["searxng"]
    )
      )
    ),
    context_strategy: ContextStrategyConfig(
      strategy: csSummarizeOld,
      maxTurns: 40,
      keepLastNTurns: 10,
      maxTokens: 16384
    ),
    memory: MemoryConfig(
      enabled: true,
      maxFacts: 1000,
      extractFacts: true
    )
  )

proc parseEnv*(cfg: var Config) =
  # Simple manual environment variable parsing to match Go's env library
  if existsEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE"): cfg.agents.defaults.workspace = getEnv("NIMCLAW_AGENTS_DEFAULTS_WORKSPACE")
  if existsEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL"): cfg.agents.defaults.model = getEnv("NIMCLAW_AGENTS_DEFAULTS_MODEL")
  if existsEnv("NIMCLAW_AGENTS_DEFAULTS_PROVIDER"): cfg.agents.defaults.provider = getEnv("NIMCLAW_AGENTS_DEFAULTS_PROVIDER")
  if existsEnv("BRAVE_API_KEY"): cfg.tools.web.search.api_key = getEnv("BRAVE_API_KEY")
  if existsEnv("EXA_API_KEY"):
    cfg.tools.web.search.providers.add(SearchProviderConfig(name: "exa", api_key: getEnv("EXA_API_KEY"), enabled: true))
    if "exa" notin cfg.tools.web.search.fallback_order:
      cfg.tools.web.search.fallback_order.add("exa")

proc loadConfig*(path: string): Config =
  let defaults = defaultConfig()
  result = defaults
  if fileExists(path):
    try:
      let data = readFile(path)
      let parsed = data.fromJson(Config)
      # Merge parsed values, keeping defaults for missing/zero fields
      if parsed.agents.defaults.workspace != "": result.agents.defaults.workspace = parsed.agents.defaults.workspace
      if parsed.agents.defaults.model != "": result.agents.defaults.model = parsed.agents.defaults.model
      if parsed.agents.defaults.provider != "": result.agents.defaults.provider = parsed.agents.defaults.provider
      if parsed.agents.defaults.max_tokens != 0: result.agents.defaults.max_tokens = parsed.agents.defaults.max_tokens
      if parsed.agents.defaults.temperature != 0.0: result.agents.defaults.temperature = parsed.agents.defaults.temperature
      if parsed.agents.defaults.max_tool_iterations != 0: result.agents.defaults.max_tool_iterations = parsed.agents.defaults.max_tool_iterations
      result.channels = parsed.channels
      result.providers = parsed.providers
      if parsed.gateway.host != "": result.gateway.host = parsed.gateway.host
      if parsed.gateway.port != 0: result.gateway.port = parsed.gateway.port
      if parsed.tools.web.search.providers.len > 0: result.tools.web.search = parsed.tools.web.search
      # Context strategy: use parsed only if maxTurns > 0, else keep defaults
      if parsed.context_strategy.maxTurns > 0: result.context_strategy = parsed.context_strategy
      # Memory: use parsed if explicitly enabled or has non-zero values
      if parsed.memory.enabled or parsed.memory.maxFacts > 0: result.memory = parsed.memory
    except CatchableError:
      discard

  parseEnv(result)

  # Backward-compat: if old api_key is present but no explicit providers,
  # auto-migrate to a Brave provider in the fallback chain.
  if result.tools.web.search.api_key != "" and result.tools.web.search.providers.len == 0:
    result.tools.web.search.providers.add(SearchProviderConfig(
      name: "brave", api_key: result.tools.web.search.api_key, enabled: true
    ))
    result.tools.web.search.fallback_order = @["brave", "searxng"]
  elif result.tools.web.search.providers.len == 0:
    # If nothing configured, default to SearXNG (self-hosted, truly free)
    result.tools.web.search.providers = @[
      SearchProviderConfig(name: "searxng", base_url: "http://localhost:8888", enabled: true)
    ]
    result.tools.web.search.fallback_order = @["searxng"]

proc saveConfig*(path: string, cfg: Config) =
  let dir = parentDir(path)
  if not dirExists(dir):
    createDir(dir)
  writeFile(path, cfg.toJson())

proc workspacePath*(cfg: Config): string =
  expandHome(cfg.agents.defaults.workspace)

proc getAPIKey*(cfg: Config): string =
  if cfg.providers.openrouter.api_key != "": return cfg.providers.openrouter.api_key
  if cfg.providers.anthropic.api_key != "": return cfg.providers.anthropic.api_key
  if cfg.providers.openai.api_key != "": return cfg.providers.openai.api_key
  if cfg.providers.gemini.api_key != "": return cfg.providers.gemini.api_key
  if cfg.providers.zhipu.api_key != "": return cfg.providers.zhipu.api_key
  if cfg.providers.groq.api_key != "": return cfg.providers.groq.api_key
  if cfg.providers.vllm.api_key != "": return cfg.providers.vllm.api_key
  if cfg.providers.kimi.api_key != "": return cfg.providers.kimi.api_key
  return ""

proc getAPIBase*(cfg: Config): string =
  if cfg.providers.openrouter.api_key != "":
    if cfg.providers.openrouter.api_base != "": return cfg.providers.openrouter.api_base
    return "https://openrouter.ai/api/v1"
  if cfg.providers.zhipu.api_key != "": return cfg.providers.zhipu.api_base
  if cfg.providers.vllm.api_key != "" and cfg.providers.vllm.api_base != "": return cfg.providers.vllm.api_base
  if cfg.providers.kimi.api_key != "":
    if cfg.providers.kimi.api_base != "": return cfg.providers.kimi.api_base
    return "https://api.moonshot.cn/v1"
  return ""
