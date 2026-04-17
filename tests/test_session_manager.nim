# Test for session manager load/save
import std/unittest, std/os, std/strutils, std/sequtils, std/options
import nimclaw/session
import nimclaw/providers/types as providers_types

suite "SessionManager load/save":
  const tmpDir = "/tmp/nimclaw_test_session"
  setup:
    if dirExists(tmpDir): removeDir(tmpDir)
    createDir(tmpDir)
  teardown:
    if dirExists(tmpDir): removeDir(tmpDir)

  test "create, add record, save, reload":
    let sm = newSessionManager(tmpDir)
    let key = "testkey"
    var session = sm.getOrCreate(key)
    check session.key == key
    check session.records.len == 0

    let msg = providers_types.Message(role: mrUser, content: some("hello"))
    sm.addFullMessage(key, msg)
    check sm.getRecordCount(key) == 1

    # Save session
    sm.save(session)
    # Ensure file exists
    let filePath = tmpDir / (key & ".jsonl")
    check fileExists(filePath)

    # Load fresh manager
    let sm2 = newSessionManager(tmpDir)
    let loaded = sm2.getOrCreate(key)
    check loaded.records.len == 1
    let loadedMsg = loaded.records[0].content
    check loadedMsg == "hello"

  test "truncation marks synthetic":
    let sm = newSessionManager(tmpDir)
    let key = "trunc"
    var s = sm.getOrCreate(key)
    for i in 1..10:
      sm.addMessage(key, "assistant", "msg" & $i)
    check s.records.len == 10
    sm.truncateHistory(key, 5)
    let records = sm.getRecords(key)
    check records.len == 10
    # first 5 should be synthetic
    for i in 0..4:
      check records[i].synthetic
    for i in 5..9:
      check not records[i].synthetic

# Ensure logging output appears by checking trace level
# (actual log output will be printed to stdout during tests)
