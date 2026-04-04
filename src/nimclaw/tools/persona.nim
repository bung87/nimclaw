## Persona Management Tool
##
## Allows the AI agent to manage its own personas

import chronos
import std/[tables, json, strutils, re, times]
import types
import ../persona/manager as pm

type
  PersonaTool* = ref object of Tool
    personaManager*: pm.PersonaManager

proc newPersonaTool*(manager: pm.PersonaManager): PersonaTool =
  PersonaTool(personaManager: manager)

method name*(t: PersonaTool): string = "persona"

method description*(t: PersonaTool): string = """Manage AI assistant personas.

Personas define the AI's personality, identity, and behavior. Use this tool to:
- List available personas
- Create new personas with custom personalities
- Update existing persona traits
- Switch to a different persona for this session

Each persona consists of:
- SOUL: Personality, values, communication style
- IDENTITY: Name, role, background
- AGENTS: Task-specific instructions and capabilities

The active persona affects how the assistant responds and behaves."""

method parameters*(t: PersonaTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["list", "get", "create", "update", "switch", "delete"],
        "description": "Action to perform"
    },
    "name": {
      "type": "string",
      "description": "Persona name/slug (for get/create/update/switch/delete)"
    },
    "soul": {
      "type": "string",
      "description": "Personality content (SOUL.md) for create/update"
    },
    "identity": {
      "type": "string",
      "description": "Identity content (IDENTITY.md) for create/update"
    },
    "agents": {
      "type": "string",
      "description": "Agent instructions (AGENTS.md) for create/update"
    },
    "field": {
      "type": "string",
      "enum": ["soul", "identity", "agents", "user"],
      "description": "Which field to update (for update action)"
    }
  },
    "required": %["action"]
  }.toTable

proc handleList(t: PersonaTool): Future[string] {.async.} =
  let personas = t.personaManager.listPersonas()
  if personas.len == 0:
    return "No personas found. Use 'create' to make one."

  var result = "Available personas:\n"
  for slug in personas:
    let summary = t.personaManager.getPersonaSummary(slug)
    result.add("- " & summary & "\n")

  return result

proc handleGet(t: PersonaTool, name: string): Future[string] {.async.} =
  try:
    let persona = t.personaManager.loadPersona(name)
    var result = "Persona: $1 (slug: $2)\n".format(persona.name, persona.slug)
    result.add("=".repeat(40) & "\n\n")

    if persona.soul.len > 0:
      result.add("## SOUL\n" & persona.soul[0..min(200, persona.soul.len-1)] & "...\n\n")

    if persona.identity.len > 0:
      result.add("## IDENTITY\n" & persona.identity[0..min(200, persona.identity.len-1)] & "...\n\n")

    if persona.metadata.model.len > 0:
      result.add("Model override: " & persona.metadata.model & "\n")

    return result
  except pm.PersonaError as e:
    return "Error: " & e.msg

proc handleCreate(t: PersonaTool, name, soul, identity: string): Future[string] {.async.} =
  # Generate slug from name
  var slug = name.toLowerAscii().splitWhitespace().join("-")
  slug = slug.replace(re"[^a-z0-9-]", "")

  if t.personaManager.personaExists(slug):
    return "Error: Persona '$1' already exists".format(slug)

  let persona = pm.Persona(
    name: name,
    slug: slug,
    soul: soul,
    identity: identity,
    agents: """# Agent Instructions

You are a helpful AI assistant.""",
    user: "",
    metadata: pm.PersonaMetadata(
      temperature: 0.7,
      createdAt: getTime().toUnix(),
      updatedAt: getTime().toUnix()
    )
  )

  try:
    t.personaManager.savePersona(persona)
    return "Created persona '$1' (slug: $2). Use 'switch' to activate it.".format(name, slug)
  except CatchableError as e:
    return "Error creating persona: " & e.msg

proc handleUpdate(t: PersonaTool, name, field, content: string): Future[string] {.async.} =
  try:
    var persona = t.personaManager.loadPersona(name)

    case field:
      of "soul":
        persona.soul = content
      of "identity":
        persona.identity = content
      of "agents":
        persona.agents = content
      of "user":
        persona.user = content
      else:
        return "Error: Unknown field '$1'. Use: soul, identity, agents, user".format(field)

    persona.metadata.updatedAt = getTime().toUnix()
    t.personaManager.savePersona(persona)

    return "Updated persona '$1' ($2). Changes will apply to new sessions.".format(persona.name, field)
  except pm.PersonaError as e:
    return "Error: " & e.msg

proc handleSwitch(t: PersonaTool, name: string, sessionKey: string): Future[string] {.async.} =
  try:
    # For now, use a default session key if not provided
    let key = if sessionKey.len > 0: sessionKey else: "default"
    t.personaManager.setActivePersona(key, name)
    let persona = t.personaManager.loadPersona(name)
    return "Switched to persona '$1'. The assistant will now respond as this persona.".format(persona.name)
  except pm.PersonaError as e:
    return "Error: " & e.msg

proc handleDelete(t: PersonaTool, name: string): Future[string] {.async.} =
  try:
    t.personaManager.deletePersona(name)
    return "Deleted persona '$1'.".format(name)
  except pm.PersonaError as e:
    return "Error: " & e.msg

method execute*(t: PersonaTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' parameter required"

  let action = args["action"].getStr()
  let name = if args.hasKey("name"): args["name"].getStr() else: ""

  case action:
    of "list":
      return await handleList(t)
    of "get":
      if name.len == 0:
        return "Error: 'name' required for get action"
      return await handleGet(t, name)
    of "create":
      if name.len == 0:
        return "Error: 'name' required for create action"
      let soul = if args.hasKey("soul"): args["soul"].getStr() else: ""
      let identity = if args.hasKey("identity"): args["identity"].getStr() else: ""
      return await handleCreate(t, name, soul, identity)
    of "update":
      if name.len == 0:
        return "Error: 'name' required for update action"
      let field = if args.hasKey("field"): args["field"].getStr() else: ""
      let content = if args.hasKey("content"): args["content"].getStr() else: ""
      if field.len == 0 or content.len == 0:
        return "Error: 'field' and 'content' required for update action"
      return await handleUpdate(t, name, field, content)
    of "switch":
      if name.len == 0:
        return "Error: 'name' required for switch action"
      let sessionKey = if args.hasKey("session_key"): args["session_key"].getStr() else: "default"
      return await handleSwitch(t, name, sessionKey)
    of "delete":
      if name.len == 0:
        return "Error: 'name' required for delete action"
      return await handleDelete(t, name)
    else:
      return "Error: Unknown action '$1'. Use: list, get, create, update, switch, delete".format(action)
