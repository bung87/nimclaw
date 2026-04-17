import chronos
import std/[os, json, strutils, tables, locks, options, times]
import ../bus, ../bus_types, ../config, ../logger, ../providers/types as providers_types,
    ../providers/adapters as providers_adapters, ../session, ../utils
import context as agent_context
import memory as agent_memory
import ../persona/manager as persona_manager
import ../checkpoint/manager as checkpoint_manager
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../tools/[filesystem, edit, shell, spawn, subagent, web, cron as cron_tool, message, persona, fact]

type
  ProcessOptions* = object
    sessionKey*: string
    channel*: string
    chatID*: string
    userMessage*: string
    defaultResponse*: string
    enableSummary*: bool
    sendResponse*: bool

  AgentLoop* = ref object
    bus*: MessageBus
    provider*: LLMProvider
    cfg*: Config
    workspace*: string
    model*: string
    temperature*: float64
    contextWindow*: int
    maxIterations*: int
    sessions*: SessionManager
    contextBuilder*: ContextBuilder
    tools*: ToolRegistry
    checkpointManager*: checkpoint_manager.CheckpointManager
    currentTurn*: Table[string, int] # sessionKey -> turn number
    running*: bool
    summarizing*: Table[string, bool]
    summarizingLock*: Lock

proc newAgentLoop*(cfg: Config, msgBus: MessageBus, provider: LLMProvider): AgentLoop =
  let workspace = cfg.workspacePath()
  if not dirExists(workspace):
    createDir(workspace)

  let toolsRegistry = newToolRegistry()

  # Register all tools faithfully as in Go
  toolsRegistry.register(ReadFileTool())
  toolsRegistry.register(WriteFileTool())
  toolsRegistry.register(ListDirTool())
  toolsRegistry.register(newExecTool(workspace))

  toolsRegistry.register(newWebSearchTool(cfg.tools.web.search))
  toolsRegistry.register(newWebFetchTool(50000))

  let msgTool = newMessageTool()
  msgTool.setSendCallback(proc(channel, chatID, content: string): Future[void] {.async.} =
    msgBus.publishOutbound(OutboundMessage(channel: channel, chat_id: chatID, content: content))
  )
  toolsRegistry.register(msgTool)

  let subagentManager = newSubagentManager(provider, workspace, msgBus)
  toolsRegistry.register(newSpawnTool(subagentManager))

  toolsRegistry.register(newEditFileTool(workspace))
  toolsRegistry.register(newAppendFileTool())

  let sessionsManager = newSessionManager(workspace / "sessions")
  let contextBuilder = newContextBuilder(workspace)
  contextBuilder.setToolsRegistry(toolsRegistry)

  # Register persona management tool (after contextBuilder is created)
  toolsRegistry.register(newPersonaTool(contextBuilder.personaManager))

  # Register fact management tool
  toolsRegistry.register(newFactTool(contextBuilder.memory))

  let cpManager = checkpoint_manager.newCheckpointManager(workspace)

  var al = AgentLoop(
    bus: msgBus,
    provider: provider,
    cfg: cfg,
    workspace: workspace,
    model: cfg.agents.defaults.model,
    temperature: cfg.agents.defaults.temperature,
    contextWindow: cfg.agents.defaults.max_tokens,
    maxIterations: cfg.agents.defaults.max_tool_iterations,
    sessions: sessionsManager,
    contextBuilder: contextBuilder,
    tools: toolsRegistry,
    checkpointManager: cpManager,
    currentTurn: initTable[string, int](),
    running: false,
    summarizing: initTable[string, bool]()
  )
  initLock(al.summarizingLock)
  return al

proc stop*(al: AgentLoop) =
  al.running = false

proc registerTool*(al: AgentLoop, tool: Tool) =
  al.tools.register(tool)

proc estimateTokens(messages: seq[providers_types.Message]): int =
  var total = 0
  for m in messages:
    let contentLen = if m.content.isSome: m.content.get().len else: 0
    total += contentLen div 4
  return total

proc summarizeBatch(al: AgentLoop, batch: seq[providers_types.Message], existingSummary: string): Future[
    string] {.async.} =
  var prompt = "Provide a concise summary of this conversation segment, preserving core context and key points.\n"
  if existingSummary != "":
    prompt.add("Existing context: " & existingSummary & "\n")
  prompt.add("\nCONVERSATION:\n")
  for m in batch:
    let roleStr = m.role.toString()
    let content = if m.content.isSome: m.content.get() else: ""
    prompt.add(roleStr & ": " & content & "\n")

  let response = await al.provider.chat(
    @[providers_types.Message(role: mrUser, content: some(prompt))],
    @[],
    al.model,
    initTable[string, JsonNode]()
  )
  return if response.content.isSome: response.content.get() else: ""

proc summarizeSession(al: AgentLoop, sessionKey: string) {.async.} =
  let history = al.sessions.getHistory(sessionKey)
  let summary = al.sessions.getSummary(sessionKey)
  let keepMessages = max(al.cfg.context_strategy.keepLastNTurns * 2, 4)

  if history.len <= keepMessages: return
  let toSummarize = history[0 .. ^(keepMessages + 1)]

  # Oversized Message Guard
  let maxMessageTokens = al.contextWindow div 2
  var validMessages: seq[providers_types.Message] = @[]
  for m in toSummarize:
    if m.role == mrUser or m.role == mrAssistant:
      let contentLen = if m.content.isSome: m.content.get().len else: 0
      if (contentLen div 4) < maxMessageTokens:
        validMessages.add(m)

  if validMessages.len == 0: return

  let finalSummary = await al.summarizeBatch(validMessages, summary)

  if finalSummary != "":
    al.sessions.setSummary(sessionKey, finalSummary)
    al.sessions.truncateHistory(sessionKey, keepMessages)
    al.sessions.save(al.sessions.getOrCreate(sessionKey))

proc maybeSummarize(al: AgentLoop, sessionKey: string) =
  acquire(al.summarizingLock)
  if al.summarizing.hasKey(sessionKey) and al.summarizing[sessionKey]:
    release(al.summarizingLock)
    return

  let history = al.sessions.getHistory(sessionKey)
  let tokenEstimate = estimateTokens(history)
  let strategy = al.cfg.context_strategy.strategy
  let maxTurns = if al.cfg.context_strategy.maxTurns > 0: al.cfg.context_strategy.maxTurns else: 40
  let keepLastNTurns = if al.cfg.context_strategy.keepLastNTurns > 0: al.cfg.context_strategy.keepLastNTurns else: 10
  let maxTokens = if al.cfg.context_strategy.maxTokens > 0: al.cfg.context_strategy.maxTokens else: 16384

  var shouldSummarize = false

  case strategy:
  of csFullHistory:
    # Only summarize when token budget is exceeded
    if tokenEstimate > maxTokens:
      shouldSummarize = true
  of csLastNTurns:
    # Truncate history when it exceeds maxTurns
    if history.len > maxTurns:
      shouldSummarize = true
  of csSummarizeOld:
    # Keep recent turns verbatim, summarize older ones
    if history.len > maxTurns or tokenEstimate > (maxTokens * 75) div 100:
      shouldSummarize = true

  if shouldSummarize:
    al.summarizing[sessionKey] = true
    release(al.summarizingLock)
    discard (proc() {.async.} =
      await summarizeSession(al, sessionKey)
      acquire(al.summarizingLock)
      al.summarizing[sessionKey] = false
      release(al.summarizingLock)
    )()
  else:
    release(al.summarizingLock)

type
  ContentUpdateCallback* = proc(thinking: string, response: string, isDone: bool) {.gcsafe.}

proc getEffectiveModel(al: AgentLoop, sessionKey: string): string =
  let persona = al.contextBuilder.personaManager.getActivePersona(sessionKey)
  if persona.metadata.model.len > 0:
    return persona.metadata.model
  return al.model

proc getEffectiveTemperature(al: AgentLoop, sessionKey: string): float64 =
  let persona = al.contextBuilder.personaManager.getActivePersona(sessionKey)
  if persona.metadata.temperature != 0.0:
    return persona.metadata.temperature
  return al.temperature

proc runLLMIteration(al: AgentLoop, messages: seq[providers_types.Message], opts: ProcessOptions,
    onUpdate: ContentUpdateCallback = nil): Future[(string, int,
    seq[providers_types.Message])] {.async.} =
  var iteration = 0
  var accumulatedContent = ""
  var accumulatedReasoning = ""
  var currentMessages = messages

  let effectiveModel = getEffectiveModel(al, opts.sessionKey)
  let effectiveTemperature = getEffectiveTemperature(al, opts.sessionKey)

  var options = initTable[string, JsonNode]()
  options["temperature"] = %effectiveTemperature
  options["max_tokens"] = %al.contextWindow

  while iteration < al.maxIterations:
    iteration += 1
    debug "LLM iteration", topic = "agent", iteration = $iteration, max = $al.maxIterations, model = effectiveModel

    let activePersona = al.contextBuilder.personaManager.getActivePersona(opts.sessionKey)
    let toolDefinitions = al.tools.getDefinitionsFiltered(activePersona.metadata.enabledTools)

    let response = await al.provider.chat(currentMessages, toolDefinitions, effectiveModel, options)

    # Accumulate reasoning across iterations
    if response.reasoning.isSome and response.reasoning.get().len > 0:
      if accumulatedReasoning.len > 0:
        accumulatedReasoning.add("\n\n")
      accumulatedReasoning.add(response.reasoning.get())

    if response.tool_calls.len == 0:
      let respContent = if response.content.isSome: response.content.get() else: ""
      if respContent.len > 0:
        if accumulatedContent.len > 0:
          accumulatedContent.add("\n\n")
        accumulatedContent.add(respContent)
      info "LLM response without tool calls", topic = "agent", iteration = $iteration
      if onUpdate != nil:
        try:
          onUpdate(accumulatedReasoning, accumulatedContent, true)
        except:
          discard
      break

    # Surface assistant content even when tool calls are present
    if response.content.isSome and response.content.get().len > 0:
      if accumulatedContent.len > 0:
        accumulatedContent.add("\n\n")
      accumulatedContent.add(response.content.get())

    if onUpdate != nil:
      try:
        onUpdate(accumulatedReasoning, accumulatedContent, false)
      except:
        discard

    var assistantMsg = providers_types.Message(
      role: mrAssistant,
      content: response.content,
      toolCalls: response.tool_calls
    )
    currentMessages.add(assistantMsg)
    al.sessions.addFullMessage(opts.sessionKey, assistantMsg)

    # Save checkpoint before executing tools (for crash recovery)
    if response.tool_calls.len > 0:
      let turn = al.currentTurn.getOrDefault(opts.sessionKey, 0)
      let checkpoint = checkpoint_manager.Checkpoint(
        sessionKey: opts.sessionKey,
        iteration: iteration,
        turn: turn,
        messages: currentMessages,
        pendingToolCalls: response.tool_calls,
        accumulatedContent: accumulatedContent,
        accumulatedReasoning: accumulatedReasoning,
        createdAt: getTime().toUnix()
      )
      try:
        al.checkpointManager.save(checkpoint)
        debug "Saved checkpoint", session = opts.sessionKey, turn = turn, iteration = iteration
      except CatchableError as e:
        warn "Failed to save checkpoint", error = e.msg

    var allToolErrors: seq[string] = @[]
    for tc in response.tool_calls:
      if tc.name == "":
        warn "Skipping tool call with empty name", topic = "agent", iteration = $iteration
        continue
      info "Tool call", topic = "agent", name = tc.name, iteration = $iteration
      let toolResult = await al.tools.executeWithContext(tc.name, tc.arguments, opts.channel, opts.chatID)
      if toolResult.startsWith("Error: "):
        allToolErrors.add(tc.name & ": " & toolResult)
      let toolResultMsg = providers_types.Message(
        role: mrTool,
        content: some(toolResult),
        toolCallId: some(tc.id),
        name: some(tc.name)
      )
      currentMessages.add(toolResultMsg)
      al.sessions.addFullMessage(opts.sessionKey, toolResultMsg)

    # If all tools failed, return error directly to user
    if allToolErrors.len > 0 and allToolErrors.len == response.tool_calls.len:
      accumulatedContent = allToolErrors.join("\n")
      if onUpdate != nil:
        try:
          onUpdate(accumulatedReasoning, accumulatedContent, true)
        except:
          discard
      break

  let resultContent = formatWithThinking(accumulatedReasoning, accumulatedContent)

  # Clean up checkpoints on successful completion
  if iteration < al.maxIterations:
    let turn = al.currentTurn.getOrDefault(opts.sessionKey, 0)
    al.checkpointManager.deleteAll(opts.sessionKey)
    debug "Cleaned up checkpoints", session = opts.sessionKey

  return (resultContent, iteration, currentMessages)

proc resumeFromCheckpoint*(al: AgentLoop, sessionKey: string): Future[bool] {.async.} =
  ## Resume agent loop from a checkpoint
  ## Returns true if successfully resumed

  if not al.checkpointManager.hasCheckpoints(sessionKey):
    return false

  try:
    var checkpoint = al.checkpointManager.loadLatest(sessionKey)
    info "Resuming from checkpoint", session = sessionKey, turn = checkpoint.turn, iteration = checkpoint.iteration

    # Restore state
    al.currentTurn[sessionKey] = checkpoint.turn

    # Re-execute pending tool calls
    var allToolErrors: seq[string] = @[]
    var currentMessages = checkpoint.messages
    for tc in checkpoint.pendingToolCalls:
      info "Re-executing tool from checkpoint", name = tc.name
      let toolResult = await al.tools.executeWithContext(tc.name, tc.arguments, "", "")
      if toolResult.startsWith("Error: "):
        allToolErrors.add(tc.name & ": " & toolResult)

      let toolResultMsg = providers_types.Message(
        role: mrTool,
        content: some(toolResult),
        toolCallId: some(tc.id),
        name: some(tc.name)
      )
      currentMessages.add(toolResultMsg)
      al.sessions.addFullMessage(sessionKey, toolResultMsg)

    # Continue from where we left off
    let opts = ProcessOptions(
      sessionKey: sessionKey,
      channel: "",
      chatID: "",
      userMessage: "",
      defaultResponse: "",
      enableSummary: true,
      sendResponse: false
    )

    # Create a new messages sequence starting from checkpoint
    let (_, finalIteration, _) = await al.runLLMIteration(currentMessages, opts, nil)

    info "Resumed session completed", session = sessionKey, iterations = finalIteration
    return true

  except CatchableError as e:
    warn "Failed to resume from checkpoint", session = sessionKey, error = e.msg
    return false

proc runAgentLoop*(al: AgentLoop, opts: ProcessOptions): Future[string] {.async.} =
  # Increment turn counter for this session
  let currentTurn = al.currentTurn.getOrDefault(opts.sessionKey, 0)
  al.currentTurn[opts.sessionKey] = currentTurn + 1

  let history = al.sessions.getHistory(opts.sessionKey)
  let summary = al.sessions.getSummary(opts.sessionKey)
  var messages: seq[providers_types.Message] = @[]
  try:
    messages = al.contextBuilder.buildMessages(history, summary, opts.userMessage, opts.channel, opts.chatID,
        opts.sessionKey)
  except CatchableError as e:
    error "Failed to build messages", topic = "agent", error = e.msg

  al.sessions.addMessage(opts.sessionKey, "user", opts.userMessage)

  let (responseContent, iteration, _) = await al.runLLMIteration(messages, opts)
  var resultContent = responseContent

  if resultContent == "":
    resultContent = opts.defaultResponse

  al.sessions.addMessage(opts.sessionKey, "assistant", resultContent)
  al.sessions.save(al.sessions.getOrCreate(opts.sessionKey))

  if opts.enableSummary:
    al.maybeSummarize(opts.sessionKey)

  # Auto-extract facts if enabled
  if al.cfg.memory.extractFacts:
    let conversation = "User: " & opts.userMessage & "\n\nAssistant: " & resultContent
    al.contextBuilder.memory.extractAndStoreFacts(conversation, opts.sessionKey)

  if opts.sendResponse:
    al.bus.publishOutbound(OutboundMessage(channel: opts.channel, chat_id: opts.chatID, content: resultContent))

  info "Response", topic = "agent", content = truncate(resultContent, 120), session_key = opts.sessionKey,
      iterations = $iteration
  return resultContent

proc processMessage*(al: AgentLoop, msg: InboundMessage): Future[string] {.async.} =
  info "Processing message", topic = "agent", channel = msg.channel, sender = msg.sender_id,
      session_key = msg.session_key

  # update tool contexts
  try:
    let (toolMsg, okMsg) = al.tools.get("message")
    if okMsg:
      if toolMsg of MessageTool: cast[MessageTool](toolMsg).setContext(msg.channel, msg.chat_id)
    let (toolSpawn, okSpawn) = al.tools.get("spawn")
    if okSpawn:
      if toolSpawn of SpawnTool: cast[SpawnTool](toolSpawn).setContext(msg.channel, msg.chat_id)
    let (toolCron, okCron) = al.tools.get("cron")
    if okCron:
      if toolCron of CronTool: cast[CronTool](toolCron).setContext(msg.channel, msg.chat_id)
  except CatchableError:
    discard

  if msg.channel == "system":
    # logic for system messages...
    return ""

  return await al.runAgentLoop(ProcessOptions(
    sessionKey: msg.session_key,
    channel: msg.channel,
    chatID: msg.chat_id,
    userMessage: msg.content,
    defaultResponse: "I have no response to give.",
    enableSummary: true,
    sendResponse: false
  ))

proc processDirect*(al: AgentLoop, content, sessionKey: string,
    onUpdate: ContentUpdateCallback = nil): Future[string] {.async.} =
  let history = al.sessions.getHistory(sessionKey)
  let summary = al.sessions.getSummary(sessionKey)
  var messages: seq[providers_types.Message] = @[]
  try:
    messages = al.contextBuilder.buildMessages(history, summary, content, "cli", "direct", sessionKey)
  except CatchableError as e:
    error "Failed to build messages", topic = "agent", error = e.msg

  al.sessions.addMessage(sessionKey, "user", content)

  let opts = ProcessOptions(
    sessionKey: sessionKey,
    channel: "cli",
    chatID: "direct",
    userMessage: content,
    defaultResponse: "I have no response to give.",
    enableSummary: true,
    sendResponse: false
  )
  let (resultContent, iteration, _) = await al.runLLMIteration(messages, opts, onUpdate)
  var responseContent = resultContent

  if responseContent == "":
    responseContent = opts.defaultResponse

  al.sessions.addMessage(sessionKey, "assistant", responseContent)
  al.sessions.save(al.sessions.getOrCreate(sessionKey))

  if opts.enableSummary:
    al.maybeSummarize(sessionKey)

  # Auto-extract facts if enabled
  if al.cfg.memory.extractFacts:
    let conversation = "User: " & content & "\n\nAssistant: " & responseContent
    al.contextBuilder.memory.extractAndStoreFacts(conversation, sessionKey)

  info "Response", topic = "agent", content = truncate(responseContent, 120), session_key = sessionKey,
      iterations = $iteration
  return responseContent

proc run*(al: AgentLoop) {.async.} =
  al.running = true
  while al.running:
    let msg = await al.bus.consumeInbound()
    let response = await al.processMessage(msg)
    if response != "":
      al.bus.publishOutbound(OutboundMessage(channel: msg.channel, chat_id: msg.chat_id, content: response))

proc getStartupInfo*(al: AgentLoop): Table[string, JsonNode] =
  var info = initTable[string, JsonNode]()
  info["tools"] = %*{"count": al.tools.list().len, "names": al.tools.list()}
  info["skills"] = %al.contextBuilder.getSkillsInfo()
  return info
