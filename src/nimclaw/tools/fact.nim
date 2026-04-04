## Fact Management Tool
##
## Allows the AI agent to remember and recall user preferences and facts

import chronos
import std/[tables, json, options]
import types
import ../agent/memory

type
  FactTool* = ref object of Tool
    memory*: MemoryStore

proc newFactTool*(memory: MemoryStore): FactTool =
  FactTool(memory: memory)

method name*(t: FactTool): string = "fact"

method description*(t: FactTool): string = """Manage user facts and preferences for long-term memory.

Use this tool to:
- Remember user preferences ("user prefers Python", "user likes dark mode")
- Store important facts about the user or project
- Recall previously stored information
- Search for facts by keyword

Examples:
- remember: key="preferred_language", value="Python"
- get: key="preferred_language" -> returns "Python"
- search: query="language" -> returns all facts about languages
- list: returns all stored facts"""

method parameters*(t: FactTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "action": {
        "type": "string",
        "enum": ["remember", "get", "has", "search", "list", "forget"],
        "description": "Action to perform"
    },
    "key": {
      "type": "string",
      "description": "Fact key (for remember/get/has/forget)"
    },
    "value": {
      "type": "string",
      "description": "Fact value (for remember)"
    },
    "query": {
      "type": "string",
      "description": "Search query (for search)"
    }
  },
    "required": %["action"]
  }.toTable

proc handleRemember(t: FactTool, key, value: string): string =
  if key.len == 0 or value.len == 0:
    return "Error: key and value required"

  t.memory.rememberFact(key, value)
  return "Remembered: " & key & " = " & value

proc handleGet(t: FactTool, key: string): string =
  if key.len == 0:
    return "Error: key required"

  let value = t.memory.getFact(key)
  if value.isSome:
    return key & ": " & value.get()
  else:
    return "No fact found for key: " & key

proc handleHas(t: FactTool, key: string): string =
  if key.len == 0:
    return "Error: key required"

  if t.memory.hasFact(key):
    return "Yes, fact exists: " & key
  else:
    return "No, fact does not exist: " & key

proc handleSearch(t: FactTool, query: string): string =
  if query.len == 0:
    return "Error: query required"

  let facts = t.memory.searchFacts(query)
  if facts.len == 0:
    return "No facts found matching: " & query

  var output = "Found " & $facts.len & " fact(s):\n"
  for fact in facts:
    output.add("- " & fact.key & ": " & fact.value & "\n")
  return output

proc handleList(t: FactTool): string =
  let facts = t.memory.searchFacts("") # Empty query returns all
  if facts.len == 0:
    return "No facts stored yet."

  var output = "Stored facts:\n"
  for fact in facts:
    output.add("- " & fact.key & ": " & fact.value & "\n")
  return output

proc handleForget(t: FactTool, key: string): string =
  if key.len == 0:
    return "Error: key required"

  if t.memory.forgetFact(key):
    return "Forgot: " & key
  else:
    return "No fact found to forget: " & key

method execute*(t: FactTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("action"):
    return "Error: 'action' parameter required"

  let action = args["action"].getStr()

  case action:
    of "remember":
      let key = if args.hasKey("key"): args["key"].getStr() else: ""
      let value = if args.hasKey("value"): args["value"].getStr() else: ""
      return handleRemember(t, key, value)

    of "get":
      let key = if args.hasKey("key"): args["key"].getStr() else: ""
      return handleGet(t, key)

    of "has":
      let key = if args.hasKey("key"): args["key"].getStr() else: ""
      return handleHas(t, key)

    of "search":
      let query = if args.hasKey("query"): args["query"].getStr() else: ""
      return handleSearch(t, query)

    of "list":
      return handleList(t)

    of "forget":
      let key = if args.hasKey("key"): args["key"].getStr() else: ""
      return handleForget(t, key)

    else:
      return "Error: Unknown action '" & action & "'. Use: remember, get, has, search, list, forget"
