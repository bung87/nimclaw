import std/[os, strutils, httpclient, json]

type
  SkillInstaller* = ref object
    workspace*: string
    builtinSkillsDir*: string

proc newSkillInstaller*(workspace: string): SkillInstaller =
  let builtinDir = getCurrentDir() / "skills"
  SkillInstaller(
    workspace: workspace,
    builtinSkillsDir: builtinDir
  )

proc getWorkspaceSkillsDir(si: SkillInstaller): string =
  si.workspace / "skills"

proc tryFetch(url: string, client: HttpClient): tuple[success: bool, content: string] =
  try:
    let response = client.get(url)
    if response.code == Http200:
      return (true, response.body)
    return (false, "")
  except:
    return (false, "")

proc fetchSkillContent(repo: string, subPath: string = ""): tuple[content: string, format: string] =
  ## Try multiple locations and formats for skill content
  ## Returns content and detected format (skill_md, readme, claude_plugin)
  
  var client = newHttpClient()
  client.timeout = 10000
  
  let basePath = if subPath != "": repo & "/" & subPath else: repo
  
  # Try SKILL.md first (our standard)
  var url = "https://raw.githubusercontent.com/" & basePath & "/main/SKILL.md"
  var (success, content) = tryFetch(url, client)
  if success: 
    client.close()
    return (content, "skill_md")
  
  url = "https://raw.githubusercontent.com/" & basePath & "/master/SKILL.md"
  (success, content) = tryFetch(url, client)
  if success: 
    client.close()
    return (content, "skill_md")
  
  # Try README.md as fallback
  url = "https://raw.githubusercontent.com/" & basePath & "/main/README.md"
  (success, content) = tryFetch(url, client)
  if success: 
    client.close()
    return (content, "readme")
  
  url = "https://raw.githubusercontent.com/" & basePath & "/master/README.md"
  (success, content) = tryFetch(url, client)
  if success: 
    client.close()
    return (content, "readme")
  
  client.close()
  raise newException(IOError, "No SKILL.md or README.md found in " & repo & 
    (if subPath != "": "/" & subPath else: ""))

proc detectRepoStructure(repo: string): seq[string] =
  ## Detect if repo contains multiple skills in subdirectories
  ## Returns list of skill subdirectories
  result = @[]
  
  var client = newHttpClient()
  client.timeout = 10000
  
  # Try to fetch repo contents via GitHub API
  let apiUrl = "https://api.github.com/repos/" & repo.split('/')[0] & "/" & repo.split('/')[1] & "/contents"
  try:
    let response = client.get(apiUrl)
    if response.code == Http200:
      let data = parseJson(response.body)
      for item in data:
        if item["type"].getStr() == "dir":
          let dirName = item["name"].getStr()
          # Skip common non-skill directories
          if dirName notin [".git", ".github", ".docs", ".claude-plugin", "scripts", "tests", "docs"]:
            result.add(dirName)
  except:
    discard
  
  client.close()

proc installFromGitHub*(si: SkillInstaller, repo: string): string =
  ## Install a skill from GitHub
  ## Supports:
  ##   - owner/repo (single skill at root)
  ##   - owner/repo/subdir (specific skill in subdirectory)
  ##   - owner/repo (auto-detect and install all subdir skills)
  
  let parts = repo.split('/')
  if parts.len < 2:
    raise newException(IOError, "Invalid repo format. Use: owner/repo or owner/repo/subdir")
  
  # Check if specific subdir specified
  if parts.len > 2:
    # Specific skill path: owner/repo/subdir
    let skillName = lastPathPart(repo)
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    let (content, format) = fetchSkillContent(parts[0] & "/" & parts[1], parts[2..^1].join("/"))
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    createDir(skillDir)
    
    # Save as SKILL.md regardless of source format
    writeFile(skillDir / "SKILL.md", content)
    return skillName
  
  # No subdir specified - try root first
  let baseRepo = parts[0] & "/" & parts[1]
  
  try:
    # Try to install from root
    let (content, format) = fetchSkillContent(baseRepo)
    let skillName = lastPathPart(baseRepo)
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    createDir(skillDir)
    writeFile(skillDir / "SKILL.md", content)
    return skillName
  
  except IOError:
    # Root doesn't have skill file - try to detect subdirectories
    let subdirs = detectRepoStructure(baseRepo)
    
    if subdirs.len == 0:
      raise newException(IOError, "No skills found in " & repo & ". Repository should contain SKILL.md or README.md")
    
    # Found subdirectories - install all as separate skills
    var installed: seq[string] = @[]
    var errors: seq[string] = @[]
    
    for subdir in subdirs:
      try:
        let (content, format) = fetchSkillContent(baseRepo, subdir)
        let skillDir = si.getWorkspaceSkillsDir() / subdir
        
        if dirExists(skillDir):
          errors.add(subdir & " (already exists)")
          continue
        
        if not dirExists(si.getWorkspaceSkillsDir()):
          createDir(si.getWorkspaceSkillsDir())
        createDir(skillDir)
        writeFile(skillDir / "SKILL.md", content)
        installed.add(subdir)
      except:
        errors.add(subdir & " (" & getCurrentExceptionMsg() & ")")
    
    if installed.len == 0:
      if errors.len > 0:
        raise newException(IOError, "Failed to install skills: " & errors.join(", "))
      else:
        raise newException(IOError, "No valid skills found in subdirectories")
    
    return installed.join(", ")

proc installFromPath*(si: SkillInstaller, sourcePath: string, skillName: string = ""): string =
  ## Install a skill from a local path
  let src = absolutePath(sourcePath)
  let name = if skillName != "": skillName else: lastPathPart(src)
  let destDir = si.getWorkspaceSkillsDir() / name

  if dirExists(destDir):
    raise newException(IOError, "Skill '" & name & "' already exists")

  if not dirExists(si.getWorkspaceSkillsDir()):
    createDir(si.getWorkspaceSkillsDir())

  if fileExists(src):
    createDir(destDir)
    copyFile(src, destDir / "SKILL.md")
  elif dirExists(src):
    copyDir(src, destDir)
  else:
    raise newException(IOError, "Source not found: " & sourcePath)

  return name

proc installBuiltin*(si: SkillInstaller, skillName: string): string =
  ## Install a built-in skill
  let builtinPath = si.builtinSkillsDir / skillName
  if not dirExists(builtinPath):
    raise newException(IOError, "Built-in skill '" & skillName & "' not found")
  return si.installFromPath(builtinPath, skillName)

proc createSkill*(si: SkillInstaller, skillName: string, description: string = ""): string =
  ## Create a new skill with template
  let skillDir = si.getWorkspaceSkillsDir() / skillName
  
  if dirExists(skillDir):
    raise newException(IOError, "Skill '" & skillName & "' already exists")

  if not dirExists(si.getWorkspaceSkillsDir()):
    createDir(si.getWorkspaceSkillsDir())
  
  createDir(skillDir)
  
  let content = """---
name: $1
description: $2
author: user
tags: []
---

# $1

Describe your skill here...

## Usage

Explain how to use this skill...
""" % [skillName, if description != "": description else: "A custom skill"]

  writeFile(skillDir / "SKILL.md", content)
  return skillDir

proc uninstall*(si: SkillInstaller, skillName: string) =
  let skillDir = si.getWorkspaceSkillsDir() / skillName
  if not dirExists(skillDir):
    raise newException(IOError, "Skill '" & skillName & "' not found")
  removeDir(skillDir)

proc listInstalledSkills*(si: SkillInstaller): seq[string] =
  result = @[]
  let skillsDir = si.getWorkspaceSkillsDir()
  if not dirExists(skillsDir):
    return result
  
  for kind, path in walkDir(skillsDir):
    if kind == pcDir:
      let skillFile = path / "SKILL.md"
      if fileExists(skillFile):
        result.add(lastPathPart(path))

proc listBuiltinSkills*(si: SkillInstaller): seq[string] =
  result = @[]
  if not dirExists(si.builtinSkillsDir):
    return result
  
  for kind, path in walkDir(si.builtinSkillsDir):
    if kind == pcDir:
      let skillFile = path / "SKILL.md"
      if fileExists(skillFile):
        result.add(lastPathPart(path))

proc getSkillInfo*(si: SkillInstaller, skillName: string): tuple[name, path: string, exists: bool] =
  let skillDir = si.getWorkspaceSkillsDir() / skillName
  let skillFile = skillDir / "SKILL.md"
  if fileExists(skillFile):
    return (skillName, skillFile, true)
  return (skillName, "", false)
