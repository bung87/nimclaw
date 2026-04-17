import std/[os, times, strutils, sequtils, tables, json, options]
import ../providers/types as providers_types
import ../skills/loader as skills_loader
import ../tools/registry as tools_registry
import ../persona/manager as persona_manager
import ../context/loader as context_loader
import memory

type
  ContextBuilder* = ref object
    workspace*: string
    skillsLoader*: SkillsLoader
    memory*: MemoryStore
    tools*: ToolRegistry
    personaManager*: persona_manager.PersonaManager
    fundamentalLoader*: context_loader.FundamentalPromptLoader

proc getGlobalConfigDir(): string =
  getHomeDir() / ".nimclaw"

proc newContextBuilder*(workspace: string): ContextBuilder =
  let wd = getCurrentDir()
  let builtinSkillsDir = wd / "skills"
  # ~/.config/agents/skills is where npx skills installs symlinks
  let globalSkillsDir = getHomeDir() / ".config" / "agents" / "skills"
  let pm = persona_manager.newPersonaManager(workspace)

  # Migrate legacy personas and ensure default exists
  pm.migrateLegacyPersonas(workspace)
  pm.createDefaultPersona()

  ContextBuilder(
    workspace: workspace,
    skillsLoader: newSkillsLoader(workspace, globalSkillsDir, builtinSkillsDir),
    memory: newMemoryStore(workspace),
    personaManager: pm,
    fundamentalLoader: context_loader.newFundamentalPromptLoader(workspace)
  )

proc setToolsRegistry*(cb: ContextBuilder, registry: ToolRegistry) =
  cb.tools = registry

proc buildToolsSection(cb: ContextBuilder): string =
  if cb.tools == nil: return ""
  let summaries = cb.tools.getSummaries()
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc buildToolPolicySection*(): string =
  result = """## Tool Calling Policy

1. **ALWAYS use tools** - When you need to perform an action (read files, execute commands, send messages, etc.), you MUST call the appropriate tool. Do NOT just say you'll do it or pretend to do it.

2. **CRITICAL: Tool Calling Format** - When calling a tool, you MUST populate the `tool_calls` field, NOT the `content` field. The response must include:
   - `tool_calls`: array of tool calls
   - Each tool call has: `type: "function"`, `function.name`, and `function.arguments` (as JSON string)

   WRONG: content = "{\"name\": \"list_dir\", ...}"
   CORRECT: tool_calls = [{"type": "function", "function": {"name": "list_dir", "arguments": "{\"path\": \"/workspace\"}"}}]

   The content field should be null or empty when making tool calls.

3. **Filesystem Rules** - When exploring code or directories:
   - Use `list_dir` on directories BEFORE using `read_file`
   - `read_file` only works on files, NEVER on directories
   - Use absolute paths exactly as returned by `list_dir`
   - Do NOT concatenate or modify paths returned by tools

4. **Be helpful and accurate** - When using tools, briefly explain what you're doing.

5. **CONTINUE AUTONOMOUSLY** - When you receive tool results, analyze them and proceed with the next step immediately. DO NOT ask the user "Would you like me to...?" or "Should I...?". Just DO IT. Keep working until the task is complete.

6. **Memory** - When remembering something, write to the workspace memory/MEMORY.md file or use the fact tool."""

proc getIdentity(cb: ContextBuilder): string =
  let now = now().format("yyyy-MM-dd HH:mm (dddd)")
  let workspacePath = absolutePath(cb.workspace)
  let runtime = hostOS & " " & hostCPU & ", Nim " & NimVersion
  let toolsSection = cb.buildToolsSection()

  let cwd = getCurrentDir()
  var identity = """# nimclaw

You are nimclaw, a helpful AI assistant.

## Current Time
$1

## Runtime
$2

## Current Working Directory
$5

## Workspace
Your workspace is at: $3
- Memory: $3/memory/MEMORY.md
- Daily Notes: $3/memory/YYYYMM/YYYYMMDD.md
- Skills: $3/skills/{skill-name}/SKILL.md

$4""".format(now, runtime, workspacePath, toolsSection, cwd)

  if toolsSection.len > 0:
    identity.add("\n\n" & buildToolPolicySection())

  return identity

proc loadPersonaFiles(cb: ContextBuilder, sessionKey: string = ""): string =
  ## Load persona files from active persona for session
  let persona = cb.personaManager.getActivePersona(sessionKey)

  var content = ""
  if persona.soul.len > 0:
    content.add("## SOUL.md\n\n" & persona.soul & "\n\n")
  if persona.identity.len > 0:
    content.add("## IDENTITY.md\n\n" & persona.identity & "\n\n")
  if persona.agents.len > 0:
    content.add("## AGENTS.md\n\n" & persona.agents & "\n\n")
  if persona.user.len > 0:
    content.add("## USER.md\n\n" & persona.user & "\n\n")

  return content

proc buildSystemPrompt*(cb: ContextBuilder, sessionKey: string = ""): string =
  var parts: seq[string] = @[]

  # <identity> section
  parts.add("<identity>\n\n" & cb.getIdentity() & "\n\n</identity>")

  # <instructions> section: fundamental prompt + persona
  var instructionsParts: seq[string] = @[]

  let fundamentalPrompt = cb.fundamentalLoader.buildFundamentalPrompt()
  if fundamentalPrompt != "":
    instructionsParts.add(fundamentalPrompt)

  let personaContent = cb.loadPersonaFiles(sessionKey)
  if personaContent != "":
    instructionsParts.add(personaContent)

  # Fallback to legacy workspace root files if nothing else found
  if instructionsParts.len == 0:
    let bootstrapFiles = ["AGENTS.md", "SOUL.md", "USER.md", "IDENTITY.md"]
    for filename in bootstrapFiles:
      let filePath = cb.workspace / filename
      if fileExists(filePath):
        instructionsParts.add("## $1\n\n$2".format(filename, readFile(filePath)))

  if instructionsParts.len > 0:
    parts.add("<instructions>\n\n" & instructionsParts.join("\n\n---\n\n") & "\n\n</instructions>")

  # <skills> section
  let skillsSummary = cb.skillsLoader.buildSkillsSummary()
  if skillsSummary != "":
    parts.add("""<skills>

The following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.

$1

</skills>""".format(skillsSummary))

  # <memory> section
  let memoryContext = cb.memory.getMemoryContext()
  if memoryContext != "":
    parts.add("<memory>\n\n" & memoryContext & "\n\n</memory>")

  return parts.join("\n\n")

proc buildMessages*(cb: ContextBuilder, history: seq[providers_types.Message], summary: string, currentMessage: string,
    channel, chatID: string, sessionKey: string = ""): seq[providers_types.Message] =
  var systemPrompt = cb.buildSystemPrompt(sessionKey)

  # Append session context outside of XML tags for clarity
  var sessionContext = ""
  if channel != "" and chatID != "":
    sessionContext.add("Channel: $1\nChat ID: $2".format(channel, chatID))

  if summary != "":
    if sessionContext.len > 0:
      sessionContext.add("\n\n")
    sessionContext.add("## Summary of Previous Conversation\n\n" & summary)

  if sessionContext.len > 0:
    systemPrompt.add("\n\n<session>\n\n" & sessionContext & "\n\n</session>")

  var messages: seq[providers_types.Message] = @[]
  messages.add(providers_types.Message(role: mrSystem, content: some(systemPrompt)))
  messages.add(history)
  messages.add(providers_types.Message(role: mrUser, content: some(currentMessage)))
  return messages

proc getSkillsInfo*(cb: ContextBuilder): Table[string, JsonNode] =
  let allSkills = cb.skillsLoader.listSkills()
  let skillNames = allSkills.mapIt(it.name)
  var info = initTable[string, JsonNode]()
  info["total"] = %allSkills.len
  info["available"] = %allSkills.len
  info["names"] = %skillNames
  return info
