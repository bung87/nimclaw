import std/[os, strutils, httpclient]

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

proc fetchFromGitHub(repo: string): string =
  ## Fetch SKILL.md from GitHub repo
  ## Format: owner/repo or owner/repo/path
  let url = "https://raw.githubusercontent.com/" & repo & "/main/SKILL.md"
  var client = newHttpClient()
  try:
    let response = client.get(url)
    if response.code == Http200:
      return response.body
    # Try master branch if main fails
    let urlMaster = "https://raw.githubusercontent.com/" & repo & "/master/SKILL.md"
    let responseMaster = client.get(urlMaster)
    if responseMaster.code == Http200:
      return responseMaster.body
    raise newException(IOError, "Failed to fetch skill from " & repo & " (HTTP " & $response.code & ")")
  except:
    raise newException(IOError, "Failed to fetch skill: " & getCurrentExceptionMsg())
  finally:
    client.close()

proc installFromGitHub*(si: SkillInstaller, repo: string): string =
  ## Install a skill from GitHub
  ## repo format: "owner/repo" or "owner/repo/subdir"
  let skillName = lastPathPart(repo.split('/')[1..^1].join("/"))
  let skillDir = si.getWorkspaceSkillsDir() / skillName

  if dirExists(skillDir):
    raise newException(IOError, "Skill '" & skillName & "' already exists")

  let content = fetchFromGitHub(repo)
  
  if not dirExists(si.getWorkspaceSkillsDir()):
    createDir(si.getWorkspaceSkillsDir())
  createDir(skillDir)
  writeFile(skillDir / "SKILL.md", content)
  
  return skillName

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
