## Security Utilities
## Input validation and path sanitization functions

import std/[strutils, os, unicode]
import pkg/regex except re

const
  # Safe characters for session keys - using regex from pkg/regex
  SessionKeyPattern = r"^[a-zA-Z0-9:_\-\.]+$"

  # Max length for session keys
  MaxSessionKeyLength = 256

  # Max length for file paths
  MaxPathLength = 4096

type
  ValidationError* = object of ValueError

  PathTraversalError* = object of ValidationError

proc raiseValidationError*(msg: string) =
  raise newException(ValidationError, msg)

proc raisePathTraversalError*(msg: string) =
  raise newException(PathTraversalError, msg)

## Session Key Validation

proc isValidSessionKey*(key: string): bool =
  ## Check if a session key contains only safe characters
  ## Uses regex from pkg/regex
  if key.len == 0 or key.len > MaxSessionKeyLength:
    return false
  try:
    return key.match(re2(SessionKeyPattern))
  except:
    return false

proc validateSessionKey*(key: string): string =
  ## Validate and return a sanitized session key
  if not key.isValidSessionKey():
    raiseValidationError("Invalid session key: must contain only alphanumeric characters, colons, underscores, hyphens, and dots")
  return key

proc sanitizeSessionKey*(key: string): string =
  ## Sanitize a session key by removing unsafe characters
  result = ""
  for c in key:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', ':', '_', '-', '.'}:
      result.add(c)
  # Truncate if too long
  if result.len > MaxSessionKeyLength:
    result = result[0..<MaxSessionKeyLength]

## Path Sanitization

proc containsPathTraversal*(path: string): bool =
  ## Check if a path contains directory traversal attempts
  let normalized = path.normalizedPath()
  return normalized.contains("..") or path.contains("~")

proc isValidPathComponent*(component: string): bool =
  ## Check if a path component is safe
  if component.len == 0:
    return false
  # No null bytes, no control characters
  for c in component:
    if ord(c) < 32:
      return false
  # No leading/trailing dots or spaces (to avoid . or ..)
  if component[0] in {'.', ' '} or component[^1] in {'.', ' '}:
    return false
  return true

proc sanitizePath*(path: string): string =
  ## Sanitize a path by normalizing and removing unsafe components
  if path.len == 0:
    return ""
  if path.len > MaxPathLength:
    return path[0..<MaxPathLength]
  
  var result = path.normalizedPath()
  # Remove path traversal attempts
  result = result.replace("..", "")
  result = result.replace("~", "")
  # Remove null bytes
  result = result.replace("\0", "")
  return result

proc validatePath*(path: string): string =
  ## Validate a path and raise errors if unsafe
  if path.len == 0 or path.len > MaxPathLength:
    raiseValidationError("Invalid path: empty or too long")

  if path.containsPathTraversal():
    raisePathTraversalError("Path traversal detected: " & path)

  # Check for null bytes
  if '\0' in path:
    raiseValidationError("Path contains null bytes")

  return path.normalizedPath()

proc safeJoinPath*(base: string, components: varargs[string]): string =
  ## Safely join path components, preventing traversal
  result = base.validatePath()

  for component in components:
    if not component.isValidPathComponent():
      raiseValidationError("Invalid path component: " & component)

    # Normalize and append
    let normalized = component.validatePath()
    result = result / normalized

  # Ensure the result is still under the base directory
  let absResult = result.absolutePath()
  let absBase = base.absolutePath()

  if not absResult.startsWith(absBase):
    raisePathTraversalError("Path traversal attempt detected: " & result)

  return result

## String Validation

proc sanitizeFilename*(filename: string): string =
  ## Sanitize a filename by removing unsafe characters
  result = ""
  for c in filename:
    # Allow alphanumeric, underscore, hyphen, and dot
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}:
      result.add(c)
    elif c in {' ', '(', ')', '[', ']', '{', '}'}:
      # Allow some common safe characters
      result.add(c)
    # Replace other characters with underscore
    else:
      result.add('_')

  # Remove leading/trailing dots and spaces
  result = result.strip(chars = {'.'})

  # Ensure filename is not empty
  if result.len == 0:
    result = "unnamed"

proc isValidPort*(port: int): bool =
  ## Check if a port number is valid
  return port >= 1 and port <= 65535

proc validatePort*(port: int): int =
  ## Validate a port number
  if not port.isValidPort():
    raiseValidationError("Invalid port number: must be between 1 and 65535")
  return port

proc isValidAPIKeyFormat*(key: string): bool =
  ## Basic validation of API key format
  # Most API keys are at least 10 characters
  if key.len < 10:
    return false
  # Should be printable ASCII
  for c in key:
    if ord(c) < 32 or ord(c) > 126:
      return false
  return true

proc redactSensitive*(s: string, showFirst: int = 4, showLast: int = 4): string =
  ## Redact sensitive strings like API keys
  if s.len <= showFirst + showLast:
    return "***"
  return s[0..<showFirst] & "***" & s[^showLast..^1]
