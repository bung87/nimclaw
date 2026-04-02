import std/[os, times, strutils, sequtils, tables, json, options]
import ../providers/types as providers_types
import ../skills/loader as skills_loader
import ../tools/registry as tools_registry
import memory

type
  ContextBuilder* = ref object
    workspace*: string
    skillsLoader*: SkillsLoader
    memory*: MemoryStore
    tools*: ToolRegistry

proc getGlobalConfigDir(): string =
  getHomeDir() / ".nimclaw"

proc newContextBuilder*(workspace: string): ContextBuilder =
  let wd = getCurrentDir()
  let builtinSkillsDir = wd / "skills"
  let globalSkillsDir = getGlobalConfigDir() / "skills"

  ContextBuilder(
    workspace: workspace,
    skillsLoader: newSkillsLoader(workspace, globalSkillsDir, builtinSkillsDir),
    memory: newMemoryStore(workspace)
  )

proc setToolsRegistry*(cb: ContextBuilder, registry: ToolRegistry) =
  cb.tools = registry

proc buildToolsSection(cb: ContextBuilder): string =
  if cb.tools == nil: return ""
  let summaries = cb.tools.getSummaries()
  if summaries.len == 0: return ""

  var sb = "## Available Tools\n\n"
  sb.add("**CRITICAL**: You MUST use tools to perform actions. Do NOT pretend to execute commands or schedule tasks.\n\n")
  sb.add("You have access to the following tools:\n\n")
  for s in summaries:
    sb.add(s & "\n")
  return sb

proc getIdentity(cb: ContextBuilder): string =
  let now = now().format("yyyy-MM-dd HH:mm (dddd)")
  let workspacePath = absolutePath(cb.workspace)
  let runtime = hostOS & " " & hostCPU & ", Nim " & NimVersion
  let toolsSection = cb.buildToolsSection()

  return """# nimclaw 🦞

You are nimclaw, a helpful AI assistant.

## Current Time
$1

## Runtime
$2

## Workspace
Your workspace is at: $3
- Memory: $3/memory/MEMORY.md
- Daily Notes: $3/memory/YYYYMM/YYYYMMDD.md
- Skills: $3/skills/{skill-name}/SKILL.md

$4

## Important Rules

1. **ALWAYS use tools** - When you need to perform an action (schedule reminders, send messages, execute commands, etc.), you MUST call the appropriate tool. Do NOT just say you'll do it or pretend to do it.

2. **CRITICAL: Tool Calling Format** - When calling a tool, you MUST populate the `tool_calls` field, NOT the `content` field. The response must include:
   - `tool_calls`: array of tool calls
   - Each tool call has: `type: "function"`, `function.name`, and `function.arguments` (as JSON string)
   
   WRONG: content = "{\"name\": \"list_dir\", ...}"
   CORRECT: tool_calls = [{"type": "function", "function": {"name": "list_dir", "arguments": "{\"path\": \"/workspace\"}"}}]
   
   The content field should be null or empty when making tool calls.

3. **Be helpful and accurate** - When using tools, briefly explain what you're doing.

4. **Memory** - When remembering something, write to $3/memory/MEMORY.md""".format(now, runtime, workspacePath, toolsSection)

proc loadBootstrapFiles(cb: ContextBuilder): string =
  let bootstrapFiles = ["AGENTS.md", "SOUL.md", "USER.md", "IDENTITY.md"]
  var content = ""
  for filename in bootstrapFiles:
    let filePath = cb.workspace / filename
    if fileExists(filePath):
      content.add("## $1\n\n$2\n\n".format(filename, readFile(filePath)))
  return content

proc buildSystemPrompt*(cb: ContextBuilder): string =
  var parts: seq[string] = @[]
  parts.add(cb.getIdentity())

  let bootstrapContent = cb.loadBootstrapFiles()
  if bootstrapContent != "":
    parts.add(bootstrapContent)

  let skillsSummary = cb.skillsLoader.buildSkillsSummary()
  if skillsSummary != "":
    parts.add("""# Skills

The following skills extend your capabilities. To use a skill, read its SKILL.md file using the read_file tool.

$1""".format(skillsSummary))

  let memoryContext = cb.memory.getMemoryContext()
  if memoryContext != "":
    parts.add(memoryContext)

  return parts.join("\n\n---\n\n")

proc buildMessages*(cb: ContextBuilder, history: seq[providers_types.Message], summary: string, currentMessage: string,
    channel, chatID: string): seq[providers_types.Message] =
  var systemPrompt = cb.buildSystemPrompt()
  if channel != "" and chatID != "":
    systemPrompt.add("\n\n## Current Session\nChannel: $1\nChat ID: $2".format(channel, chatID))

  if summary != "":
    systemPrompt.add("\n\n## Summary of Previous Conversation\n\n" & summary)

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
