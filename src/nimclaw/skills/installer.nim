import std/[os, strutils, httpclient, json, uri]
import ../logger

type
  SkillInstaller* = ref object
    workspace*: string
    builtinSkillsDir*: string
    verbose*: bool

proc newSkillInstaller*(workspace: string): SkillInstaller =
  let builtinDir = getCurrentDir() / "skills"
  SkillInstaller(
    workspace: workspace,
    builtinSkillsDir: builtinDir,
    verbose: false
  )

proc getWorkspaceSkillsDir(si: SkillInstaller): string =
  si.workspace / "skills"

proc httpGet(url: string): string =
  var client = newHttpClient()
  client.timeout = 15000
  try:
    let response = client.get(url)
    if response.code != Http200:
      raise newException(IOError, "HTTP " & $response.code)
    return response.body
  finally:
    client.close()

proc apiGet(url: string): JsonNode =
  ## Call GitHub API with fallback error message
  try:
    let body = httpGet(url)
    return parseJson(body)
  except CatchableError as e:
    raise newException(IOError, "GitHub API failed (rate limit?): " & e.msg)

proc downloadFile(url, destPath: string) =
  let content = httpGet(url)
  writeFile(destPath, content)

proc downloadDirectoryFromRaw(si: SkillInstaller, owner, repo, path, branch, destDir: string) =
  ## Download directory using raw GitHub URLs
  ## Fallback when API rate limit is hit - only works for single-file skills
  createDir(destDir)

  let baseRawUrl = "https://raw.githubusercontent.com/" & owner & "/" & repo & "/" & branch & "/" & path

  if si.verbose:
    echo "  Raw URL fallback: " & baseRawUrl

  # Try to download README.md or SKILL.md
  var found = false
  for filename in ["README.md", "SKILL.md", "skill.md", "readme.md"]:
    try:
      let content = httpGet(baseRawUrl & "/" & filename)
      writeFile(destDir / "SKILL.md", content)
      found = true
      if si.verbose:
        echo "  Downloaded: " & filename & " (saved as SKILL.md)"
      break
    except CatchableError as e:
      debug "Failed to download file", topic = "skills", filename = filename, error = e.msg
      continue

  if not found:
    raise newException(IOError, "Could not find SKILL.md or README.md at " & baseRawUrl &
        ".\n\nNote: When GitHub API rate limit is exceeded, only single-file skills can be downloaded.\nFor repos with multiple skills in subdirectories, either:\n  1. Wait and retry later\n  2. Use: --install owner/repo/subdir (specific skill path)\n  3. Clone manually: git clone https://github.com/" &
        owner & "/" & repo & " && ./nimclaw skills --from_path ./" & repo & "/<skill-name>")

proc listDirectoryContents(owner, repo, path, branch: string): seq[tuple[name, typeName, url: string]] =
  ## List contents of a directory via GitHub API
  result = @[]
  let apiPath = if path != "": "/" & encodeUrl(path, true) else: ""
  let url = "https://api.github.com/repos/" & owner & "/" & repo & "/contents" & apiPath & "?ref=" & branch

  let data = apiGet(url)
  if data.kind == JArray:
    for item in data:
      result.add((
        item["name"].getStr(),
        item["type"].getStr(),
        item["download_url"].getStr("")
      ))

proc getDefaultBranch(owner, repo: string): string =
  try:
    let data = apiGet("https://api.github.com/repos/" & owner & "/" & repo)
    return data["default_branch"].getStr("main")
  except:
    return "main"

proc downloadDirectory(si: SkillInstaller, owner, repo, path, branch, destDir: string) =
  ## Recursively download a directory from GitHub
  createDir(destDir)

  if si.verbose:
    echo "  Fetching: " & owner & "/" & repo & "/" & path

  var contents: seq[tuple[name, typeName, url: string]]

  try:
    contents = listDirectoryContents(owner, repo, path, branch)
  except CatchableError as e:
    # API failed (rate limit?) - fallback to raw URLs
    if si.verbose:
      echo "  API failed, using raw URL fallback: " & e.msg
    downloadDirectoryFromRaw(si, owner, repo, path, branch, destDir)
    return

  if contents.len == 0:
    raise newException(IOError, "Empty directory: " & path)

  if si.verbose:
    echo "  Found " & $contents.len & " items"

  for item in contents:
    let destPath = destDir / item.name

    if item.typeName == "file":
      if item.url != "":
        if si.verbose:
          echo "  Downloading: " & item.name
        try:
          downloadFile(item.url, destPath)
        except CatchableError as e:
          raise newException(IOError, "Failed to download " & item.name & ": " & e.msg)
    elif item.typeName == "dir":
      if si.verbose:
        echo "  Entering: " & item.name
      let subPath = if path != "": path & "/" & item.name else: item.name
      downloadDirectory(si, owner, repo, subPath, branch, destPath)

proc isLikelySkillDir(owner, repo, path, branch: string): bool =
  ## Check if directory contains skill files
  try:
    let contents = listDirectoryContents(owner, repo, path, branch)
    for item in contents:
      if item.typeName == "file":
        let name = item.name.toLowerAscii
        if name == "skill.md" or name == "readme.md":
          return true
  except CatchableError as e:
    # Try raw URL fallback
    debug "API check failed, trying raw URL fallback", topic = "skills", error = e.msg
    let baseRawUrl = "https://raw.githubusercontent.com/" & owner & "/" & repo & "/" & branch & "/" & path
    try:
      discard httpGet(baseRawUrl & "/SKILL.md")
      return true
    except CatchableError:
      try:
        discard httpGet(baseRawUrl & "/README.md")
        return true
      except CatchableError:
        debug "Raw URL fallback also failed", topic = "skills"
  return false

proc installFromGitHub*(si: SkillInstaller, repo: string): string =
  ## Install skill(s) from GitHub
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

    if not dirExists(si.getWorkspaceSkillsDir()):
      createDir(si.getWorkspaceSkillsDir())

    downloadDirectory(si, owner, repoName, subPath, branch, skillDir)
    return skillName

  # Check root for skill files
  var hasSkillFile = false
  var subdirs: seq[string] = @[]

  try:
    let rootContents = listDirectoryContents(owner, repoName, "", branch)
    for item in rootContents:
      if item.typeName == "file":
        let name = item.name.toLowerAscii
        if name == "skill.md" or name == "readme.md":
          hasSkillFile = true
      elif item.typeName == "dir":
        if item.name notin [".git", ".github", ".docs", ".claude-plugin",
                          "scripts", "tests", "docs", ".gitattributes",
                          ".gitignore", "validate_plugins.py", "CONTRIBUTING.md", "LICENSE", "images", "assets"]:
          subdirs.add(item.name)
  except CatchableError:
    # API failed - assume it's a skill repo and try raw download
    hasSkillFile = true # We'll find out when we try to download
  
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
    raise newException(IOError, "No skills found in " & repo)

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
    except CatchableError as e:
      errors.add(subdir & " (" & e.msg & ")")

  if installed.len == 0:
    raise newException(IOError, "Failed to install skills: " & errors.join(", "))

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
