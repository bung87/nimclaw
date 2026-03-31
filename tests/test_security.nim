import unittest
import std/strutils
import nimclaw/security

suite "Session Key Validation":
  test "valid session keys":
    check isValidSessionKey("user:123") == true
    check isValidSessionKey("chat_1.test") == true
    check isValidSessionKey("channel-name_1") == true
    check isValidSessionKey("a") == true
    check isValidSessionKey("A-Z_0-9:.-") == true

  test "invalid characters":
    check isValidSessionKey("user<script>") == false
    check isValidSessionKey("hello world") == false
    check isValidSessionKey("path/to/file") == false
    check isValidSessionKey("key@domain") == false
    check isValidSessionKey("test#hash") == false

  test "length boundaries":
    check isValidSessionKey("") == false
    check isValidSessionKey(repeat("a", 256)) == true
    check isValidSessionKey(repeat("a", 257)) == false

  test "validateSessionKey raises on invalid":
    expect(ValidationError):
      discard validateSessionKey("invalid key!")
    
    expect(ValidationError):
      discard validateSessionKey("")

  test "validateSessionKey returns valid key":
    check validateSessionKey("valid_key") == "valid_key"

suite "Session Key Sanitization":
  test "sanitize removes unsafe characters":
    check sanitizeSessionKey("hello world!") == "helloworld"
    check sanitizeSessionKey("path/to/file") == "pathtofile"
    check sanitizeSessionKey("test@#$%") == "test"

  test "sanitize keeps safe characters":
    check sanitizeSessionKey("user:123_test.v1") == "user:123_test.v1"

  test "sanitize truncates long keys":
    let longKey = repeat("a", 300)
    let sanitized = sanitizeSessionKey(longKey)
    check sanitized.len == 256

suite "Path Traversal Detection":
  test "detects traversal patterns":
    check containsPathTraversal("../etc/passwd") == true
    check containsPathTraversal("foo/../../bar") == true
    check containsPathTraversal("~/secrets") == true
    check containsPathTraversal("/home/~user") == true

  test "safe paths pass":
    check containsPathTraversal("/etc/passwd") == false
    check containsPathTraversal("foo/bar/baz") == false
    # Note: "normal..file" contains ".." so it gets flagged (conservative approach)

suite "Path Component Validation":
  test "valid components":
    check isValidPathComponent("filename") == true
    check isValidPathComponent("file.name") == true
    check isValidPathComponent("file_name") == true

  test "invalid components":
    check isValidPathComponent("") == false
    check isValidPathComponent(".") == false
    check isValidPathComponent("..") == false
    check isValidPathComponent(" .") == false  # leading space
    check isValidPathComponent(". ") == false  # trailing space
    check isValidPathComponent("file\x00name") == false  # null byte

suite "Path Sanitization":
  test "sanitize removes traversal":
    check sanitizePath("../etc/passwd") == "/etc/passwd"
    check sanitizePath("foo/../../bar") == "/bar"  # normalized then cleaned
    check sanitizePath("~/secrets") == "/secrets"

  test "sanitize removes null bytes":
    check sanitizePath("file\x00name") == "filename"

  test "sanitize truncates long paths":
    let longPath = repeat("a", 5000)
    check sanitizePath(longPath).len <= 4096  # MaxPathLength

suite "Safe Path Joining":
  test "joins valid components":
    let joinedPath = safeJoinPath("/base", "subdir", "file.txt")
    check joinedPath == "/base/subdir/file.txt"

  test "rejects traversal attempts":
    # Path that escapes base directory (could be ValidationError or PathTraversalError)
    expect(ValueError):
      discard safeJoinPath("/home/user", "..", ".bashrc")
    
    # Normal subdir should work
    let joinedPath = safeJoinPath("/base", "subdir", "file.txt")
    check joinedPath == "/base/subdir/file.txt"

suite "Filename Sanitization":
  test "sanitizes unsafe characters":
    check sanitizeFilename("file:name.txt") == "file_name.txt"
    check sanitizeFilename("file/name") == "file_name"
    check sanitizeFilename("file@name") == "file_name"

  test "allows safe characters":
    check sanitizeFilename("file_name-v1.0") == "file_name-v1.0"
    check sanitizeFilename("file (1)") == "file (1)"  # parentheses allowed
    check sanitizeFilename("file[1]") == "file[1]"    # brackets allowed

  test "removes leading dots":
    check sanitizeFilename("..hidden") == "hidden"
    check sanitizeFilename(".hidden") == "hidden"

  test "empty becomes unnamed":
    check sanitizeFilename("") == "unnamed"
    check sanitizeFilename("!!!") == "___"

suite "Port Validation":
  test "valid ports":
    check isValidPort(1) == true
    check isValidPort(80) == true
    check isValidPort(443) == true
    check isValidPort(65535) == true

  test "invalid ports":
    check isValidPort(0) == false
    check isValidPort(-1) == false
    check isValidPort(65536) == false

  test "validatePort raises on invalid":
    expect(ValidationError):
      discard validatePort(0)

suite "API Key Format Validation":
  test "valid API key formats":
    check isValidAPIKeyFormat("sk-1234567890") == true
    check isValidAPIKeyFormat("a".repeat(50)) == true

  test "too short":
    check isValidAPIKeyFormat("short") == false
    check isValidAPIKeyFormat("123456789") == false

  test "non-printable characters":
    check isValidAPIKeyFormat("key\x01with\x02ctrl") == false

suite "Sensitive Data Redaction":
  test "redacts long strings":
    check redactSensitive("sk-1234567890abcdef") == "sk-1***cdef"
    check redactSensitive("verylongsecretkeyhere") == "very***here"

  test "redacts short strings completely":
    check redactSensitive("short") == "***"
    check redactSensitive("tiny") == "***"

  test "custom show length":
    check redactSensitive("sk-test123456", showFirst = 2, showLast = 3) == "sk***456"
