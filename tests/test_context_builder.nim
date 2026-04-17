import std/[os, strutils, times]
import ../src/nimclaw/context/loader as context_loader
import ../src/nimclaw/agent/context as agent_context

proc testFindProjectRoot() =
  let root = context_loader.findProjectRoot()
  echo "Project root: ", root
  assert root.len > 0, "findProjectRoot should return a non-empty path"
  assert dirExists(root), "Project root should exist"

proc testFundamentalPromptLoader() =
  let tmpDir = getTempDir() / "nimclaw_test_context_" & $getTime().toUnix()
  createDir(tmpDir)

  # Create workspace-level AGENTS.md
  writeFile(tmpDir / "AGENTS.md", "# Workspace Rules\n\nAlways use Nim.")

  let loader = context_loader.newFundamentalPromptLoader(tmpDir)
  let layers = loader.loadAllContext()

  # Should at least have workspace layer
  var foundWorkspace = false
  for layer in layers:
    if layer.source == "Workspace":
      foundWorkspace = true
      assert layer.content.contains("Always use Nim"), "Workspace content should contain rules"

  assert foundWorkspace, "Should find workspace context layer"

  # Clean up
  removeDir(tmpDir)

proc testSystemPromptStructure() =
  let workspace = getTempDir() / "nimclaw_test_prompt_" & $getTime().toUnix()
  createDir(workspace)

  let cb = agent_context.newContextBuilder(workspace)
  let prompt = cb.buildSystemPrompt("test-session")

  assert prompt.contains("<identity>"), "System prompt should contain <identity> section"
  assert prompt.contains("</identity>"), "System prompt should close <identity> section"
  assert prompt.contains("<instructions>"), "System prompt should contain <instructions> section"
  assert prompt.contains("</instructions>"), "System prompt should close <instructions> section"
  # <skills> and <memory> are only present when there is actual content

  # Clean up
  removeDir(workspace)

proc testHierarchicalMerge() =
  let tmpDir = getTempDir() / "nimclaw_test_hier_" & $getTime().toUnix()
  createDir(tmpDir)

  # Create multiple layers
  writeFile(tmpDir / "AGENTS.md", "Global rule")
  writeFile(tmpDir / "CLAUDE.md", "Workspace rule")

  let loader = context_loader.newFundamentalPromptLoader(tmpDir)
  let prompt = loader.buildFundamentalPrompt()

  assert prompt.contains("Global rule") or prompt.contains("Workspace rule"), "Should merge context files"

  # Clean up
  removeDir(tmpDir)

when isMainModule:
  echo "Running context builder tests..."
  testFindProjectRoot()
  echo "  ✓ findProjectRoot"
  testFundamentalPromptLoader()
  echo "  ✓ fundamental prompt loader"
  testSystemPromptStructure()
  echo "  ✓ system prompt structure"
  testHierarchicalMerge()
  echo "  ✓ hierarchical merge"
  echo "All tests passed!"
