import chronos
import std/[json, tables]

type
  Tool* = ref object of RootObj

method name*(t: Tool): string {.base, raises: [].} = ""
method description*(t: Tool): string {.base, raises: [].} = ""
method parameters*(t: Tool): Table[string, JsonNode] {.base, raises: [].} = initTable[string, JsonNode]()
method execute*(t: Tool, args: Table[string, JsonNode]): Future[string] {.base, async.} = return ""

type
  ContextualTool* = ref object of Tool

method setContext*(t: ContextualTool, channel, chatID: string) {.base, gcsafe, raises: [].} = discard
