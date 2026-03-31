import chronos
import chronos/apps/http/httpclient
import std/[os, json, strutils]

type
  AvailableSkill* = object
    name*: string
    repository*: string
    description*: string
    author*: string
    tags*: seq[string]

  BuiltinSkill* = object
    name*: string
    path*: string
    enabled*: bool

  SkillInstaller* = ref object
    workspace*: string
    session*: HttpSessionRef

proc newSkillInstaller*(workspace: string): SkillInstaller =
  SkillInstaller(
    workspace: workspace,
    session: HttpSessionRef.new()
  )

proc installFromGitHub*(si: SkillInstaller, repo: string): Future[void] {.async.} =
  let skillName = lastPathPart(repo)
  let skillDir = si.workspace / "skills" / skillName

  if dirExists(skillDir):
    raise newException(IOError, "Skill '$1' already exists".format(skillName))

  let url = "https://raw.githubusercontent.com/$1/main/SKILL.md".format(repo)
  
  let addressRes = si.session.getAddress(url)
  if addressRes.isErr:
    raise newException(IOError, "Failed to resolve URL")
  let address = addressRes.get()
  
  let request = HttpClientRequestRef.new(
    si.session,
    address,
    meth = MethodGet
  )

  try:
    let response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    let body = cast[string](bodyBytes)
    
    if response.status != 200:
      raise newException(IOError, "Failed to fetch skill: " & $response.status)

    if not dirExists(si.workspace / "skills"):
      createDir(si.workspace / "skills")
    createDir(skillDir)
    writeFile(skillDir / "SKILL.md", body)
  except Exception as e:
    raise newException(IOError, "Failed to install skill: " & e.msg)

proc uninstall*(si: SkillInstaller, skillName: string) =
  let skillDir = si.workspace / "skills" / skillName
  if not dirExists(skillDir):
    raise newException(IOError, "Skill '$1' not found".format(skillName))
  removeDir(skillDir)

proc listAvailableSkills*(si: SkillInstaller): Future[seq[AvailableSkill]] {.async.} =
  let url = "https://raw.githubusercontent.com/sipeed/picoclaw-skills/main/skills.json"
  
  let addressRes = si.session.getAddress(url)
  if addressRes.isErr:
    raise newException(IOError, "Failed to resolve URL")
  let address = addressRes.get()
  
  let request = HttpClientRequestRef.new(
    si.session,
    address,
    meth = MethodGet
  )

  try:
    let response = await request.send()
    let bodyBytes = await response.getBodyBytes()
    let body = cast[string](bodyBytes)
    
    if response.status != 200:
      raise newException(IOError, "Failed to fetch skills list: " & $response.status)

    return parseJson(body).to(seq[AvailableSkill])
  except Exception as e:
    raise newException(IOError, "Failed to list skills: " & e.msg)
