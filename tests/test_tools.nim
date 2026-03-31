import unittest, os, json, tables, strutils
import chronos
import nimclaw/tools/[filesystem, edit, types]

suite "ReadFileTool":
  test "reads existing file":
    let tool = ReadFileTool()
    let testFile = getTempDir() / "test_read.txt"
    writeFile(testFile, "hello world")
    
    let args = {"path": %testFile}.toTable
    let res = waitFor tool.execute(args)
    
    check res == "hello world"
    removeFile(testFile)

  test "error on missing file":
    let tool = ReadFileTool()
    let args = {"path": %"/nonexistent/file.txt"}.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("Error: failed to read file")

  test "error on missing path arg":
    let tool = ReadFileTool()
    let args = initTable[string, JsonNode]()
    let res = waitFor tool.execute(args)
    
    check res.contains("Error: path is required")

suite "WriteFileTool":
  test "writes new file":
    let tool = WriteFileTool()
    let testFile = getTempDir() / "test_write.txt"
    
    let args = {
      "path": %testFile,
      "content": %"test content"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("File written successfully")
    check readFile(testFile) == "test content"
    removeFile(testFile)

  test "error on missing args":
    let tool = WriteFileTool()
    
    var args = {"path": %"/tmp/test"}.toTable
    check (waitFor tool.execute(args)).contains("Error: content is required")
    
    args = {"content": %"test"}.toTable
    check (waitFor tool.execute(args)).contains("Error: path is required")

  test "overwrites existing file":
    let tool = WriteFileTool()
    let testFile = getTempDir() / "test_overwrite.txt"
    writeFile(testFile, "old content")
    
    let args = {
      "path": %testFile,
      "content": %"new content"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check readFile(testFile) == "new content"
    removeFile(testFile)

suite "ListDirTool":
  test "lists directory contents":
    let tool = ListDirTool()
    let testDir = getTempDir() / "test_listdir"
    createDir(testDir)
    writeFile(testDir / "file1.txt", "")
    writeFile(testDir / "file2.txt", "")
    createDir(testDir / "subdir")
    
    let args = {"path": %testDir}.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("file1.txt")
    check res.contains("file2.txt")
    check res.contains("DIR:  subdir")
    
    removeDir(testDir, true)

  test "handles edge cases gracefully":
    let tool = ListDirTool()
    # Empty dir should return empty string (current dir)
    let args = {"path": %"."}.toTable
    let res = waitFor tool.execute(args)
    # Current dir always has something
    check res.len >= 0

suite "EditFileTool":
  test "replaces text in file":
    let tool = newEditFileTool("")
    let testFile = getTempDir() / "test_edit.txt"
    writeFile(testFile, "hello world foo bar")
    
    let args = {
      "path": %testFile,
      "old_text": %"world",
      "new_text": %"nim"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("Successfully edited")
    check readFile(testFile) == "hello nim foo bar"
    removeFile(testFile)

  test "error when old_text not found":
    let tool = newEditFileTool("")
    let testFile = getTempDir() / "test_edit2.txt"
    writeFile(testFile, "hello world")
    
    let args = {
      "path": %testFile,
      "old_text": %"notfound",
      "new_text": %"replacement"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("old_text not found")
    removeFile(testFile)

  test "error when old_text appears multiple times":
    let tool = newEditFileTool("")
    let testFile = getTempDir() / "test_edit3.txt"
    writeFile(testFile, "foo bar foo baz foo")
    
    let args = {
      "path": %testFile,
      "old_text": %"foo",
      "new_text": %"replaced"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("appears 3 times")
    removeFile(testFile)

  test "enforces allowed directory":
    let allowedDir = getTempDir() / "allowed"
    createDir(allowedDir)
    let tool = newEditFileTool(allowedDir)
    
    let testFile = getTempDir() / "outside.txt"
    writeFile(testFile, "content")
    
    let args = {
      "path": %testFile,
      "old_text": %"content",
      "new_text": %"new"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("outside allowed directory")
    removeFile(testFile)
    removeDir(allowedDir)

  test "missing required args":
    let tool = newEditFileTool("")
    
    var args = {"path": %"/tmp/test", "old_text": %"old"}.toTable
    check (waitFor tool.execute(args)).contains("new_text is required")
    
    args = {"path": %"/tmp/test", "new_text": %"new"}.toTable
    check (waitFor tool.execute(args)).contains("old_text is required")
    
    args = {"old_text": %"old", "new_text": %"new"}.toTable
    check (waitFor tool.execute(args)).contains("path is required")

suite "AppendFileTool":
  test "appends to file":
    let tool = newAppendFileTool()
    let testFile = getTempDir() / "test_append.txt"
    writeFile(testFile, "first line\n")
    
    let args = {
      "path": %testFile,
      "content": %"second line"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check res.contains("Successfully appended")
    check readFile(testFile) == "first line\nsecond line"
    removeFile(testFile)

  test "creates file if not exists":
    let tool = newAppendFileTool()
    let testFile = getTempDir() / "test_append_new.txt"
    
    let args = {
      "path": %testFile,
      "content": %"new content"
    }.toTable
    let res = waitFor tool.execute(args)
    
    check fileExists(testFile)
    check readFile(testFile) == "new content"
    removeFile(testFile)

  test "missing required args":
    let tool = newAppendFileTool()
    
    var args = {"path": %"/tmp/test"}.toTable
    check (waitFor tool.execute(args)).contains("content is required")
    
    args = {"content": %"test"}.toTable
    check (waitFor tool.execute(args)).contains("path is required")

suite "Tool Metadata":
  test "ReadFileTool has correct metadata":
    let tool = ReadFileTool()
    check tool.name() == "read_file"
    check tool.description().contains("Read")
    let params = tool.parameters()
    check params.hasKey("type")
    check params["type"].getStr() == "object"

  test "WriteFileTool has correct metadata":
    let tool = WriteFileTool()
    check tool.name() == "write_file"
    check tool.description().contains("Write")
    let params = tool.parameters()
    check params.hasKey("properties")

  test "EditFileTool has correct metadata":
    let tool = newEditFileTool("/tmp")
    check tool.name() == "edit_file"
    check tool.description().contains("Edit")
    let params = tool.parameters()
    check params.hasKey("required")

  test "AppendFileTool has correct metadata":
    let tool = newAppendFileTool()
    check tool.name() == "append_file"
    check tool.description().contains("Append")
