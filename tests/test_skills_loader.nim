import std/[os, strutils, times]
import ../src/nimclaw/skills/loader as skills_loader

proc testFrontmatterParsing() =
  let content = """---
name: My Skill
description: A test skill for nimclaw.
---

# My Skill

This is the body of the skill.
"""

  let tmpDir = getTempDir() / "nimclaw_test_skills_" & $getTime().toUnix()
  let skillDir = tmpDir / "skills" / "my_skill"
  createDir(skillDir)
  writeFile(skillDir / "SKILL.md", content)

  let loader = skills_loader.newSkillsLoader(tmpDir, "", "")
  let skills = loader.listSkills()

  assert skills.len == 1, "Should find one skill"
  assert skills[0].name == "My Skill", "Should parse name from frontmatter"
  assert skills[0].description == "A test skill for nimclaw.", "Should parse description from frontmatter"

  removeDir(tmpDir)

proc testFallbackDescription() =
  let content = """# Awesome Skill

This skill does amazing things with Nim code. It is very useful.

## Details

More info here.
"""

  let tmpDir = getTempDir() / "nimclaw_test_skills2_" & $getTime().toUnix()
  let skillDir = tmpDir / "skills" / "awesome_skill"
  createDir(skillDir)
  writeFile(skillDir / "SKILL.md", content)

  let loader = skills_loader.newSkillsLoader(tmpDir, "", "")
  let skills = loader.listSkills()

  assert skills.len == 1, "Should find one skill"
  assert skills[0].name == "Awesome Skill", "Should fallback to H1 for name"
  assert skills[0].description.contains("This skill does amazing things"), "Should fallback to first paragraph for description"

  removeDir(tmpDir)

proc testNoFrontmatterNoH1() =
  let content = """This is just a plain skill description without any headers.

It has multiple paragraphs.
"""

  let tmpDir = getTempDir() / "nimclaw_test_skills3_" & $getTime().toUnix()
  let skillDir = tmpDir / "skills" / "plain_skill"
  createDir(skillDir)
  writeFile(skillDir / "SKILL.md", content)

  let loader = skills_loader.newSkillsLoader(tmpDir, "", "")
  let skills = loader.listSkills()

  assert skills.len == 1, "Should find one skill"
  assert skills[0].name == "plain_skill", "Should fallback to directory name"
  assert skills[0].description.contains("This is just a plain skill"), "Should extract first paragraph"

  removeDir(tmpDir)

when isMainModule:
  echo "Running skills loader tests..."
  testFrontmatterParsing()
  echo "  ✓ frontmatter parsing"
  testFallbackDescription()
  echo "  ✓ fallback description"
  testNoFrontmatterNoH1()
  echo "  ✓ no frontmatter, no h1"
  echo "All tests passed!"
