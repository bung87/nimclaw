import chronos
import std/[os, json, strutils, tables, locks, options]
import ../bus, ../bus_types, ../config, ../logger, ../providers/types as providers_types,
    ../providers/adapters as providers_adapters, ../session, ../utils
import context as agent_context
import ../tools/registry as tools_registry
import ../tools/base as tools_base
import ../tools/[filesystem, edit, shell, spawn, subagent, web, cron as cron_tool, message, persona]

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
    workspace*: string
    model*: string
    contextWindow*: int
    maxIterations*: int
    sessions*: SessionManager
    contextBuilder*: ContextBuilder
    tools*: ToolRegistry
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

  var al = AgentLoop(
    bus: msgBus,
    provider: provider,
    workspace: workspace,
    model: cfg.agents.defaults.model,
    contextWindow: cfg.agents.defaults.max_tokens,
    maxIterations: cfg.agents.defaults.max_tool_iterations,
    sessions: sessionsManager,
    contextBuilder: contextBuilder,
    tools: toolsRegistry,
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

  if history.len <= 4: return
  let toSummarize = history[0 .. ^5]

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
    al.sessions.truncateHistory(sessionKey, 4)
    al.sessions.save(al.sessions.getOrCreate(sessionKey))

proc maybeSummarize(al: AgentLoop, sessionKey: string) =
  acquire(al.summarizingLock)
  if al.summarizing.hasKey(sessionKey) and al.summarizing[sessionKey]:
    release(al.summarizingLock)
    return

  let history = al.sessions.getHistory(sessionKey)
  let tokenEstimate = estimateTokens(history)
  let threshold = (al.contextWindow * 75) div 100

  if history.len > 20 or tokenEstimate > threshold:
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

proc runLLMIteration(al: AgentLoop, messages: seq[providers_types.Message], opts: ProcessOptions,
    onUpdate: ContentUpdateCallback = nil): Future[(string, int,
    seq[providers_types.Message])] {.async.} =
  var iteration = 0
  var accumulatedContent = ""
  var accumulatedReasoning = ""
  var currentMessages = messages

  while iteration < al.maxIterations:
    iteration += 1
    debug "LLM iteration", topic = "agent", iteration = $iteration, max = $al.maxIterations

    let response = await al.provider.chat(currentMessages, al.tools.getDefinitions(), al.model, initTable[string,
        JsonNode]())

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
  return (resultContent, iteration, currentMessages)

proc runAgentLoop*(al: AgentLoop, opts: ProcessOptions): Future[string] {.async.} =
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
