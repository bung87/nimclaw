import std/[os, strutils, tables]

type
  SkillMetadata* = object
    name*: string
    description*: string

  SkillInfo* = object
    name*: string
    path*: string
    source*: string
    description*: string

  SkillsLoader* = ref object
    workspace*: string
    workspaceSkills*: string
    globalSkills*: string
    builtinSkills*: string

proc newSkillsLoader*(workspace, globalSkills, builtinSkills: string): SkillsLoader =
  SkillsLoader(
    workspace: workspace,
    workspaceSkills: workspace / "skills",
    globalSkills: globalSkills,
    builtinSkills: builtinSkills
  )

proc stripFrontmatter(content: string): string =
  ## Remove YAML frontmatter if present
  if content.startsWith("---\n"):
    let nextIdx = content.find("\n---\n", 4)
    if nextIdx != -1:
      return content[nextIdx + 5 .. ^1].strip()
  return content.strip()

proc parseFrontmatter(content: string): Table[string, string] =
  ## Parse simple YAML frontmatter key: value pairs
  result = initTable[string, string]()
  if not content.startsWith("---\n"):
    return result
  let endIdx = content.find("\n---\n", 4)
  if endIdx == -1:
    return result

  let frontmatter = content[4 ..< endIdx]
  for line in frontmatter.splitLines():
    let trimmed = line.strip()
    if trimmed.len == 0 or trimmed.startsWith("#"):
      continue
    let colonPos = trimmed.find(':')
    if colonPos > 0:
      let key = trimmed[0 ..< colonPos].strip()
      var value = trimmed[colonPos + 1 .. ^1].strip()
      # Remove quotes if present
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1 .. ^2]
      elif value.len >= 2 and value[0] == '\'' and value[^1] == '\'':
        value = value[1 .. ^2]
      result[key] = value

proc extractFirstH1(content: string): string =
  ## Extract the first Markdown H1 heading
  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("# "):
      return trimmed[2 .. ^1].strip()
  return ""

proc extractFirstParagraph(content: string): string =
  ## Extract the first non-empty paragraph after frontmatter/headers
  var inCodeBlock = false
  var collecting = false
  var paragraph = ""

  for line in content.splitLines():
    let trimmed = line.strip()
    if trimmed.startsWith("```"):
      inCodeBlock = not inCodeBlock
      continue
    if inCodeBlock:
      continue
    if trimmed.len == 0:
      if collecting and paragraph.len > 0:
        return paragraph.strip()
      continue
    if trimmed.startsWith("#"):
      continue
    collecting = true
    if paragraph.len > 0:
      paragraph.add(" ")
    paragraph.add(trimmed)

  return paragraph.strip()

proc getSkillMetadata(sl: SkillsLoader, skillPath: string): SkillMetadata =
  let dirName = lastPathPart(parentDir(skillPath))
  if not fileExists(skillPath):
    return SkillMetadata(name: dirName, description: "")

  let content = readFile(skillPath)
  let frontmatter = parseFrontmatter(content)

  var name = dirName
  var description = ""
  var nameFromFrontmatter = false

  if frontmatter.hasKey("name"):
    name = frontmatter["name"]
    nameFromFrontmatter = true

  if frontmatter.hasKey("description"):
    description = frontmatter["description"]
  else:
    let body = stripFrontmatter(content)
    let firstPara = extractFirstParagraph(body)
    if firstPara.len > 0:
      # Limit to first sentence or 200 chars
      let sentenceEnd = firstPara.find('.')
      if sentenceEnd > 10:
        description = firstPara[0 .. sentenceEnd]
      else:
        description = firstPara
      if description.len > 200:
        description = description[0 .. 199] & "..."

  # Only fall back to H1 if no explicit frontmatter name was provided
  if not nameFromFrontmatter and name == dirName:
    let h1 = extractFirstH1(stripFrontmatter(content))
    if h1.len > 0:
      name = h1

  SkillMetadata(name: name, description: description)

proc listSkillsFromDir(sl: SkillsLoader, dir, sourceLabel: string, result: var seq[SkillInfo]) =
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcDir or kind == pcLinkToDir:
      let skillFile = path / "SKILL.md"
      if fileExists(skillFile):
        let meta = getSkillMetadata(sl, skillFile)
        result.add(SkillInfo(
          name: meta.name,
          path: skillFile,
          source: sourceLabel,
          description: meta.description
        ))

proc listSkills*(sl: SkillsLoader): seq[SkillInfo] =
  result = @[]
  listSkillsFromDir(sl, sl.builtinSkills, "builtin", result)
  listSkillsFromDir(sl, sl.globalSkills, "global", result)
  # Fallback: npx skills may install symlinks in ~/.config/agents/skills
  # pointing to ~/.agents/skills, but some skills (e.g. manually installed)
  # may only exist in ~/.config/agents/skills
  let configAgentsDir = getHomeDir() / ".config" / "agents" / "skills"
  if configAgentsDir != sl.globalSkills and dirExists(configAgentsDir):
    listSkillsFromDir(sl, configAgentsDir, "global", result)
  listSkillsFromDir(sl, sl.workspaceSkills, "workspace", result)
  # Deduplicate by name (prefer earlier sources)
  var seen = initTable[string, bool]()
  var deduped: seq[SkillInfo] = @[]
  for s in result:
    if not seen.hasKey(s.name):
      seen[s.name] = true
      deduped.add(s)
  result = deduped

proc loadSkill*(sl: SkillsLoader, name: string): (string, bool) =
  for dir in [sl.workspaceSkills, sl.globalSkills, sl.builtinSkills]:
    if dir == "": continue
    let skillFile = dir / name / "SKILL.md"
    if fileExists(skillFile):
      return (readFile(skillFile), true)
  return ("", false)

proc loadSkillsForContext*(sl: SkillsLoader, skillNames: seq[string]): string =
  if skillNames.len == 0: return ""
  var parts: seq[string] = @[]
  for name in skillNames:
    let (content, ok) = sl.loadSkill(name)
    if ok:
      parts.add("### Skill: " & name & "\n\n" & content)
  return parts.join("\n\n---\n\n")

proc escapeXML(s: string): string =
  s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

proc buildSkillsSummary*(sl: SkillsLoader): string =
  let skills = sl.listSkills()
  if skills.len == 0: return ""
  var lines = @["<skills>"]
  for s in skills:
    lines.add("  <skill>")
    lines.add("    <name>" & escapeXML(s.name) & "</name>")
    lines.add("    <description>" & escapeXML(s.description) & "</description>")
    lines.add("    <location>" & escapeXML(s.path) & "</location>")
    lines.add("    <source>" & s.source & "</source>")
    lines.add("  </skill>")
  lines.add("</skills>")
  return lines.join("\n")
