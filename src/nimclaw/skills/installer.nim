import std/[os, strutils, httpclient, json, uri]

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

proc apiGet(url: string): JsonNode =
  var client = newHttpClient()
  client.timeout = 15000
  try:
    let response = client.get(url)
    if response.code != Http200:
      raise newException(IOError, "GitHub API error: " & $response.code)
    return parseJson(response.body)
  finally:
    client.close()

proc rawGet(url: string): string =
  var client = newHttpClient()
  client.timeout = 15000
  try:
    let response = client.get(url)
    if response.code != Http200:
      raise newException(IOError, "Failed to fetch: " & $response.code)
    return response.body
  finally:
    client.close()

proc findSkillFile(owner, repo, path, branch: string): tuple[url, format: string] =
  ## Check if SKILL.md or README.md exists at the given path
  let apiUrl = "https://api.github.com/repos/" & owner & "/" & repo & "/contents/" & path & "?ref=" & branch
  
  try:
    let data = apiGet(apiUrl)
    if data.kind == JArray:
      # It's a directory - look for files
      for item in data:
        if item["type"].getStr() == "file":
          let name = item["name"].getStr().toLowerAscii
          if name == "skill.md":
            return (item["download_url"].getStr(), "skill_md")
          if name == "readme.md":
            return (item["download_url"].getStr(), "readme")
    elif data.kind == JObject and data["type"].getStr() == "file":
      # Single file
      return (data["download_url"].getStr(), "skill_md")
  except:
    discard
  
  raise newException(IOError, "No SKILL.md or README.md found")

proc getDefaultBranch(owner, repo: string): string =
  ## Get the default branch (main or master)
  try:
    let data = apiGet("https://api.github.com/repos/" & owner & "/" & repo)
    return data["default_branch"].getStr("main")
  except:
    return "main"

proc listSubdirs(owner, repo, branch: string): seq[string] =
  ## List subdirectories in repo root
  result = @[]
  try:
    let data = apiGet("https://api.github.com/repos/" & owner & "/" & repo & "/contents?ref=" & branch)
    if data.kind == JArray:
      for item in data:
        if item["type"].getStr() == "dir":
          let name = item["name"].getStr()
          # Skip common non-skill directories
          if name notin [".git", ".github", ".docs", ".claude-plugin", 
                        "scripts", "tests", "docs", ".gitattributes", 
                        ".gitignore", "validate_plugins.py", "CONTRIBUTING.md", "LICENSE"]:
            result.add(name)
  except:
    discard

proc installFromGitHub*(si: SkillInstaller, repo: string): string =
  ## Install skill(s) from GitHub
  ## Supports: owner/repo, owner/repo/path/to/skill
  
  let parts = repo.split('/')
  if parts.len < 2:
    raise newException(IOError, "Invalid format. Use: owner/repo or owner/repo/subdir")
  
  let owner = parts[0]
  let repoName = parts[1]
  let branch = getDefaultBranch(owner, repoName)
  
  # If path specified, install specific skill
  if parts.len > 2:
    let subPath = parts[2..^1].join("/")
    let skillName = lastPathPart(subPath)
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    let (url, format) = findSkillFile(owner, repoName, subPath, branch)
    let content = rawGet(url)
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    createDir(skillDir)
    writeFile(skillDir / "SKILL.md", content)
    return skillName
  
  # No path - try root first
  try:
    let (url, format) = findSkillFile(owner, repoName, "", branch)
    let content = rawGet(url)
    let skillName = repoName
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    createDir(skillDir)
    writeFile(skillDir / "SKILL.md", content)
    return skillName
  
  except IOError:
    # No skill at root - check subdirectories
    let subdirs = listSubdirs(owner, repoName, branch)
    
    if subdirs.len == 0:
      raise newException(IOError, "No skills found in " & repo)
    
    var installed: seq[string] = @[]
    var errors: seq[string] = @[]
    
    for subdir in subdirs:
      try:
        let (url, format) = findSkillFile(owner, repoName, subdir, branch)
        let content = rawGet(url)
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
        errors.add(subdir)
    
    if installed.len == 0:
      raise newException(IOError, "No valid skills found")
    
    return installed.join(", ")

proc installFromPath*(si: SkillInstaller, sourcePath: string, skillName: string = ""): string =
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
  let builtinPath = si.builtinSkillsDir / skillName
  if not dirExists(builtinPath):
    raise newException(IOError, "Built-in skill '" & skillName & "' not found")
  return si.installFromPath(builtinPath, skillName)

proc createSkill*(si: SkillInstaller, skillName: string, description: string = ""): string =
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
