import std/[os, strutils]

type
  ContextLayer* = object
    source*: string
    path*: string
    content*: string

  FundamentalPromptLoader* = ref object
    workspace*: string
    globalDir*: string

proc newFundamentalPromptLoader*(workspace: string): FundamentalPromptLoader =
  result = FundamentalPromptLoader(
    workspace: workspace,
    globalDir: getHomeDir() / ".nimclaw"
  )

proc findProjectRoot*(): string =
  ## Walk up from current directory looking for project markers
  var current = getCurrentDir()
  while true:
    if dirExists(current / ".git"):
      return current
    if fileExists(current / "nimclaw.nimble"):
      return current
    if fileExists(current / "config.nims"):
      return current
    let parent = parentDir(current)
    if parent == current or parent == "":
      break
    current = parent
  return getCurrentDir()

proc readContextFile(path: string): string =
  if fileExists(path):
    return readFile(path).strip()
  return ""

proc pickPrimaryFile(dir: string, baseNames: seq[string]): string =
  ## Pick the first existing file from baseNames in the given directory
  for name in baseNames:
    let path = dir / name
    if fileExists(path):
      return path
  return ""

proc loadLayer(path, sourceLabel: string): ContextLayer =
  let content = readContextFile(path)
  ContextLayer(source: sourceLabel, path: path, content: content)

proc loadGlobalContext*(loader: FundamentalPromptLoader): seq[ContextLayer] =
  ## Load global context from ~/.nimclaw/
  result = @[]
  let globalPath = pickPrimaryFile(loader.globalDir, @["CLAUDE.md", "AGENTS.md"])
  if globalPath != "":
    result.add(loadLayer(globalPath, "Global"))

proc loadWorkspaceContext*(loader: FundamentalPromptLoader): seq[ContextLayer] =
  ## Load workspace-level context
  result = @[]
  let workspacePath = pickPrimaryFile(loader.workspace, @["CLAUDE.md", "AGENTS.md"])
  if workspacePath != "":
    result.add(loadLayer(workspacePath, "Workspace"))

proc loadProjectContext*(loader: FundamentalPromptLoader): seq[ContextLayer] =
  ## Load project-root and hierarchical directory context
  result = @[]
  let projectRoot = findProjectRoot()
  let currentDir = getCurrentDir()

  # Project root level
  let rootPath = pickPrimaryFile(projectRoot, @["CLAUDE.md", "AGENTS.md"])
  if rootPath != "":
    result.add(loadLayer(rootPath, "Project Root"))

  # Hierarchical directories between project root and current dir
  if currentDir.startsWith(projectRoot) and currentDir != projectRoot:
    var relPath = currentDir[projectRoot.len .. ^1]
    if relPath.len > 0 and relPath[0] == DirSep:
      relPath = relPath[1..^1]

    var parts: seq[string] = @[]
    for part in relPath.split(DirSep):
      if part.len > 0:
        parts.add(part)

    var cumulativePath = projectRoot
    for part in parts:
      cumulativePath = cumulativePath / part
      let path = pickPrimaryFile(cumulativePath, @["CLAUDE.md", "AGENTS.md"])
      if path != "":
        # Determine a nice source label from the relative path
        let label = "Module: " & part
        result.add(loadLayer(path, label))

proc loadAllContext*(loader: FundamentalPromptLoader): seq[ContextLayer] =
  ## Load all context layers from least specific to most specific
  result = @[]
  for layer in loadGlobalContext(loader):
    result.add(layer)
  for layer in loadWorkspaceContext(loader):
    result.add(layer)
  for layer in loadProjectContext(loader):
    result.add(layer)

proc formatContextLayers*(layers: seq[ContextLayer]): string =
  ## Format layers into a single markdown document
  var parts: seq[string] = @[]
  for layer in layers:
    if layer.content.len == 0:
      continue
    parts.add("## " & layer.source & "\n\n" & layer.content)

  if parts.len == 0:
    return ""

  return parts.join("\n\n---\n\n")

proc buildFundamentalPrompt*(loader: FundamentalPromptLoader): string =
  ## Build the complete fundamental prompt from all discovered files
  let layers = loadAllContext(loader)
  return formatContextLayers(layers)
