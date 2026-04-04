## Persona Management for Nimclaw
##
## Manages AI assistant personas stored as markdown files in workspace/personas/

import std/[os, times, strutils, tables, json]
import ../logger

type
  PersonaMetadata* = object
    model*: string
    temperature*: float64
    enabledTools*: seq[string]
    createdAt*: int64
    updatedAt*: int64

  Persona* = object
    name*: string
    slug*: string
    soul*: string
    identity*: string
    agents*: string
    user*: string
    metadata*: PersonaMetadata

  PersonaManager* = ref object
    personasDir*: string
    activePersonas*: Table[string, string] # sessionKey -> personaSlug

type
  PersonaError* = object of CatchableError

proc newPersonaManager*(workspace: string): PersonaManager =
  ## Create new persona manager for given workspace
  let personasDir = workspace / "personas"
  if not dirExists(personasDir):
    try:
      createDir(personasDir)
    except CatchableError as e:
      warn "Failed to create personas directory", path = personasDir, error = e.msg

  PersonaManager(
    personasDir: personasDir,
    activePersonas: initTable[string, string]()
  )

proc personaExists*(pm: PersonaManager, slug: string): bool =
  ## Check if persona exists
  dirExists(pm.personasDir / slug)

proc getPersonaPath(pm: PersonaManager, slug: string): string =
  pm.personasDir / slug

proc loadPersona*(pm: PersonaManager, slug: string): Persona =
  ## Load persona from disk
  let personaDir = pm.getPersonaPath(slug)

  if not dirExists(personaDir):
    raise newException(PersonaError, "Persona not found: " & slug)

  var persona = Persona(slug: slug, name: slug)

  # Load SOUL.md
  let soulPath = personaDir / "SOUL.md"
  if fileExists(soulPath):
    persona.soul = readFile(soulPath)

  # Load IDENTITY.md
  let identityPath = personaDir / "IDENTITY.md"
  if fileExists(identityPath):
    persona.identity = readFile(identityPath)

  # Load AGENTS.md
  let agentsPath = personaDir / "AGENTS.md"
  if fileExists(agentsPath):
    persona.agents = readFile(agentsPath)

  # Load USER.md
  let userPath = personaDir / "USER.md"
  if fileExists(userPath):
    persona.user = readFile(userPath)

  # Load metadata
  let metadataPath = personaDir / "metadata.json"
  if fileExists(metadataPath):
    try:
      let jsonData = readFile(metadataPath).parseJson()
      persona.metadata.model = jsonData.getOrDefault("model").getStr("")
      persona.metadata.temperature = jsonData.getOrDefault("temperature").getFloat(0.7)
      if jsonData.hasKey("enabledTools"):
        for tool in jsonData["enabledTools"]:
          persona.metadata.enabledTools.add(tool.getStr())
      persona.metadata.createdAt = jsonData.getOrDefault("createdAt").getBiggestInt(0)
      persona.metadata.updatedAt = jsonData.getOrDefault("updatedAt").getBiggestInt(0)
    except CatchableError as e:
      warn "Failed to load persona metadata", persona = slug, error = e.msg

  # Derive name from identity if available
  if persona.identity.len > 0:
    for line in persona.identity.splitLines():
      if line.startsWith("Name:"):
        persona.name = line["Name:".len..^1].strip()
        break

  debug "Loaded persona", name = persona.name, slug = slug
  return persona

proc savePersona*(pm: PersonaManager, persona: Persona) =
  ## Save persona to disk
  let personaDir = pm.getPersonaPath(persona.slug)

  if not dirExists(personaDir):
    createDir(personaDir)

  # Save SOUL.md
  if persona.soul.len > 0:
    writeFile(personaDir / "SOUL.md", persona.soul)

  # Save IDENTITY.md
  if persona.identity.len > 0:
    writeFile(personaDir / "IDENTITY.md", persona.identity)

  # Save AGENTS.md
  if persona.agents.len > 0:
    writeFile(personaDir / "AGENTS.md", persona.agents)

  # Save USER.md
  if persona.user.len > 0:
    writeFile(personaDir / "USER.md", persona.user)

  # Save metadata
  var metadataJson = %*{
    "model": persona.metadata.model,
    "temperature": persona.metadata.temperature,
    "enabledTools": persona.metadata.enabledTools,
    "updatedAt": getTime().toUnix()
  }
  if persona.metadata.createdAt == 0:
    metadataJson["createdAt"] = %getTime().toUnix()
  else:
    metadataJson["createdAt"] = %persona.metadata.createdAt

  writeFile(personaDir / "metadata.json", metadataJson.pretty())

  info "Saved persona", name = persona.name, slug = persona.slug

proc listPersonas*(pm: PersonaManager): seq[string] =
  ## List all persona slugs
  if not dirExists(pm.personasDir):
    return @[]

  for kind, path in walkDir(pm.personasDir):
    if kind == pcDir:
      let slug = splitPath(path).tail
      if slug.len > 0 and slug[0] != '.':
        result.add(slug)

  return result

proc getPersonaSummary*(pm: PersonaManager, slug: string): string =
  ## Get one-line summary of persona
  try:
    let persona = pm.loadPersona(slug)
    return "$1 ($2)".format(persona.name, slug)
  except CatchableError:
    return slug

proc setActivePersona*(pm: PersonaManager, sessionKey, slug: string) =
  ## Set active persona for a session
  if not pm.personaExists(slug):
    raise newException(PersonaError, "Persona not found: " & slug)

  pm.activePersonas[sessionKey] = slug
  debug "Set active persona", session = sessionKey, persona = slug

proc getActivePersona*(pm: PersonaManager, sessionKey: string): Persona =
  ## Get active persona for a session (or default)
  let slug = pm.activePersonas.getOrDefault(sessionKey, "default")

  if pm.personaExists(slug):
    return pm.loadPersona(slug)

  # Fallback to default
  if pm.personaExists("default"):
    return pm.loadPersona("default")

  # Return empty persona if nothing exists
  return Persona(slug: "default", name: "Default")

proc deletePersona*(pm: PersonaManager, slug: string) =
  ## Delete a persona
  if slug == "default":
    raise newException(PersonaError, "Cannot delete default persona")

  let personaDir = pm.getPersonaPath(slug)
  if not dirExists(personaDir):
    raise newException(PersonaError, "Persona not found: " & slug)

  try:
    removeDir(personaDir)
    info "Deleted persona", slug = slug
  except CatchableError as e:
    raise newException(PersonaError, "Failed to delete persona: " & e.msg)

proc createDefaultPersona*(pm: PersonaManager) =
  ## Create default persona if it doesn't exist
  if pm.personaExists("default"):
    return

  info "Creating default persona"

  let defaultPersona = Persona(
    name: "Nimclaw",
    slug: "default",
    soul: """# Soul

I am nimclaw, a helpful AI assistant.

## Personality
- Helpful and efficient
- Clear and concise communication
- Professional yet friendly

## Values
- Accuracy over speed
- User empowerment through explanation
- Respect for user time""",
    identity: """# Identity

Name: Nimclaw 🦞
Role: AI Assistant
Background: Built with Nim for efficiency and speed""",
    agents: """# Agent Instructions

You are a helpful AI assistant.

## Guidelines
1. Always use tools when available
2. Be concise but thorough
3. Explain your reasoning when helpful
4. Ask clarifying questions when needed""",
    user: """# User

User preferences will be recorded here.""",
    metadata: PersonaMetadata(
      model: "",
      temperature: 0.7,
      enabledTools: @[],
      createdAt: getTime().toUnix(),
      updatedAt: getTime().toUnix()
    )
  )

  pm.savePersona(defaultPersona)
  info "Created default persona"

proc migrateLegacyPersonas*(pm: PersonaManager, workspace: string) =
  ## Migrate legacy root-level persona files to new structure
  if pm.personaExists("default"):
    return # Already migrated

  info "Migrating legacy persona files"

  var persona = Persona(
    name: "Nimclaw",
    slug: "default",
    metadata: PersonaMetadata(
      temperature: 0.7,
      createdAt: getTime().toUnix(),
      updatedAt: getTime().toUnix()
    )
  )

  # Read legacy files if they exist
  let legacyFiles = [
    ("SOUL.md", addr persona.soul),
    ("IDENTITY.md", addr persona.identity),
    ("AGENTS.md", addr persona.agents),
    ("USER.md", addr persona.user)
  ]

  for (filename, field) in legacyFiles:
    let path = workspace / filename
    if fileExists(path):
      field[] = readFile(path)
      info "Migrated legacy file", file = filename

  # Only save if we found at least one file
  if persona.soul.len > 0 or persona.identity.len > 0:
    pm.savePersona(persona)
    info "Migrated legacy persona to new structure"
  else:
    # Create fresh default
    pm.createDefaultPersona()
