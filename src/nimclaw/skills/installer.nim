import std/[os, strutils, httpclient, json, uri, sequtils]

type
  SkillInstaller* = ref object
    workspace*: string
    builtinSkillsDir*: string
    verbose*: bool

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

proc getDefaultBranch(owner, repo: string): string =
  try:
    let data = apiGet("https://api.github.com/repos/" & owner & "/" & repo)
    return data["default_branch"].getStr("main")
  except:
    return "main"

proc listDirectoryContents(owner, repo, path, branch: string): seq[tuple[name, typeName, url: string]] =
  ## List contents of a directory via GitHub API
  result = @[]
  let apiPath = if path != "": "/" & encodeUrl(path, true) else: ""
  let url = "https://api.github.com/repos/" & owner & "/" & repo & "/contents" & apiPath & "?ref=" & branch
  
  try:
    let data = apiGet(url)
    if data.kind == JArray:
      for item in data:
        result.add((
          item["name"].getStr(),
          item["type"].getStr(),
          item["download_url"].getStr("")
        ))
  except:
    discard

proc downloadDirectory(si: SkillInstaller, owner, repo, path, branch, destDir: string) =
  ## Recursively download a directory from GitHub
  createDir(destDir)
  
  if si.verbose:
    echo "  Listing: " & owner & "/" & repo & "/" & path & " (branch: " & branch & ")"
  
  let contents = listDirectoryContents(owner, repo, path, branch)
  
  if contents.len == 0:
    raise newException(IOError, "Could not list directory contents: " & owner & "/" & repo & "/" & path)
  
  if si.verbose:
    echo "  Found " & $contents.len & " items"
  
  for item in contents:
    let destPath = destDir / item.name
    
    if item.typeName == "file":
      if item.url != "":
        if si.verbose:
          echo "  Downloading: " & item.name
        try:
          let content = rawGet(item.url)
          writeFile(destPath, content)
        except CatchableError as e:
          raise newException(IOError, "Failed to download " & item.name & ": " & e.msg)
    elif item.typeName == "dir":
      if si.verbose:
        echo "  Entering directory: " & item.name
      let subPath = if path != "": path & "/" & item.name else: item.name
      downloadDirectory(si, owner, repo, subPath, branch, destPath)

proc isLikelySkillDir(owner, repo, path, branch: string): bool =
  ## Check if directory contains skill files (SKILL.md or README.md)
  let contents = listDirectoryContents(owner, repo, path, branch)
  for item in contents:
    if item.typeName == "file":
      let name = item.name.toLowerAscii
      if name == "skill.md" or name == "readme.md":
        return true
  return false

proc installFromGitHub*(si: SkillInstaller, repo: string): string =
  ## Install skill(s) from GitHub
  ## Supports:
  ##   - owner/repo (single skill at root)
  ##   - owner/repo/subdir (specific skill)
  ##   - owner/repo (auto-detect multiple skills in subdirs)
  
  let parts = repo.split('/')
  if parts.len < 2:
    raise newException(IOError, "Invalid format. Use: owner/repo or owner/repo/subdir")
  
  let owner = parts[0]
  let repoName = parts[1]
  let branch = getDefaultBranch(owner, repoName)
  
  # If path specified, install specific subdirectory
  if parts.len > 2:
    let subPath = parts[2..^1].join("/")
    let skillName = lastPathPart(subPath)
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    if not isLikelySkillDir(owner, repoName, subPath, branch):
      raise newException(IOError, "No SKILL.md or README.md found in " & repo)
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    
    downloadDirectory(si, owner, repoName, subPath, branch, skillDir)
    return skillName
  
  # Check root for skill files
  let rootContents = listDirectoryContents(owner, repoName, "", branch)
  var hasSkillFile = false
  var subdirs: seq[string] = @[]
  
  for item in rootContents:
    if item.typeName == "file":
      let name = item.name.toLowerAscii
      if name == "skill.md" or name == "readme.md":
        hasSkillFile = true
    elif item.typeName == "dir":
      # Skip common non-skill directories
      if item.name notin [".git", ".github", ".docs", ".claude-plugin", 
                        "scripts", "tests", "docs", ".gitattributes", 
                        ".gitignore", "validate_plugins.py", "CONTRIBUTING.md", "LICENSE", "images", "assets"]:
        subdirs.add(item.name)
  
  # If root has skill file, install entire repo as single skill
  if hasSkillFile:
    let skillName = repoName
    let skillDir = si.getWorkspaceSkillsDir() / skillName
    
    if dirExists(skillDir):
      raise newException(IOError, "Skill '" & skillName & "' already exists")
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    
    downloadDirectory(si, owner, repoName, "", branch, skillDir)
    return skillName
  
  # No skill at root - try subdirectories
  var skillSubdirs: seq[string] = @[]
  for subdir in subdirs:
    if isLikelySkillDir(owner, repoName, subdir, branch):
      skillSubdirs.add(subdir)
  
  if skillSubdirs.len == 0:
    raise newException(IOError, "No skills found in " & repo & ". Skills should contain SKILL.md or README.md")
  
  # Install all skill subdirectories
  var installed: seq[string] = @[]
  var errors: seq[string] = @[]
  
  for subdir in skillSubdirs:
    let skillDir = si.getWorkspaceSkillsDir() / subdir
    
    if dirExists(skillDir):
      errors.add(subdir & " (already exists)")
      continue
    
    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())
    
    try:
      downloadDirectory(si, owner, repoName, subdir, branch, skillDir)
      installed.add(subdir)
    except:
      errors.add(subdir & " (download failed)")
  
  if installed.len == 0:
    raise newException(IOError, "Failed to install skills: " & errors.join(", "))
  
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
