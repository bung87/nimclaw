import chronos
import std/[os, json, tables, strutils]
import types
import ../security

type
  ReadFileTool* = ref object of Tool
  WriteFileTool* = ref object of Tool
  ListDirTool* = ref object of Tool

# ReadFileTool
method name*(t: ReadFileTool): string = "read_file"
method description*(t: ReadFileTool): string = "Read the contents of a file. Only use on files, NOT directories. If the path is a directory, use list_dir instead."
method parameters*(t: ReadFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Absolute path to the file to read. Must be a file, not a directory."
    }
  },
    "required": %["path"]
  }.toTable

proc listDirForError(path: string): string =
  ## Helper to list a directory and include it in an error message
  result = ""
  try:
    let safePath = validatePath(path)
    if not dirExists(safePath):
      return ""
    var output = "\nContents of " & safePath & ":\n"
    for kind, entry in walkDir(safePath):
      if kind == pcDir or kind == pcLinkToDir:
        output.add("DIR:  " & entry & "\n")
      else:
        output.add("FILE: " & entry & "\n")
    return output
  except CatchableError:
    return ""

method execute*(t: ReadFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  let path = args["path"].getStr().strip()
  if path.len == 0: return "Error: path is empty"
  try:
    let safePath = validatePath(path)
    if dirExists(safePath):
      var err = "Error: path is a directory, not a file. Use list_dir to explore directories."
      let listing = listDirForError(safePath)
      if listing.len > 0:
        err.add(listing)
      return err
    if not fileExists(safePath):
      var err = "Error: file does not exist: " & safePath
      let parentDir = parentDir(safePath)
      if parentDir.len > 0 and dirExists(parentDir):
        let listing = listDirForError(parentDir)
        if listing.len > 0:
          err.add(listing)
      err.add("\nUse list_dir to find the correct path.")
      return err
    return readFile(safePath)
  except ValidationError as e:
    return "Error: " & e.msg
  except CatchableError as e:
    return "Error: failed to read file: " & e.msg

# WriteFileTool
method name*(t: WriteFileTool): string = "write_file"
method description*(t: WriteFileTool): string = "Write content to a file"
method parameters*(t: WriteFileTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Path to the file to write"
    },
    "content": {
      "type": "string",
      "description": "Content to write to the file"
    }
  },
    "required": %["path", "content"]
  }.toTable

method execute*(t: WriteFileTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  if not args.hasKey("path"): return "Error: path is required"
  if not args.hasKey("content"): return "Error: content is required"
  let path = args["path"].getStr().strip()
  let content = args["content"].getStr()
  try:
    let safePath = validatePath(path)
    let dir = parentDir(safePath)
    if dir != "" and not dirExists(dir):
      createDir(dir)
    writeFile(safePath, content)
    return "File written successfully"
  except ValidationError as e:
    return "Error: " & e.msg
  except CatchableError as e:
    return "Error: failed to write file: " & e.msg

# ListDirTool
method name*(t: ListDirTool): string = "list_dir"
method description*(t: ListDirTool): string = "List files and directories in a directory path. Use this before read_file when exploring."
method parameters*(t: ListDirTool): Table[string, JsonNode] =
  {
    "type": %"object",
    "properties": %*{
      "path": {
        "type": "string",
        "description": "Absolute path to the directory to list"
    }
  },
    "required": %["path"]
  }.toTable

method execute*(t: ListDirTool, args: Table[string, JsonNode]): Future[string] {.async.} =
  let path = if args.hasKey("path"): args["path"].getStr().strip() else: "."
  if path.len == 0: return "Error: path is empty"
  try:
    let safePath = validatePath(path)
    # Check if path exists first
    if not dirExists(safePath):
      if fileExists(safePath):
        return "Error: path is a file, not a directory: " & safePath
      else:
        return "Error: directory does not exist: " & safePath
    var output = ""
    for kind, entry in walkDir(safePath):
      let fullPath = safePath / entry
      if kind == pcDir or kind == pcLinkToDir:
        output.add("DIR:  " & fullPath & "\n")
      else:
        output.add("FILE: " & fullPath & "\n")
    return output
  except ValidationError as e:
    return "Error: " & e.msg
  except CatchableError as e:
    return "Error: failed to read directory: " & e.msg
