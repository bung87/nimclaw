# Persona Management Implementation Plan

## Overview

Implement dynamic persona management for Nimclaw, allowing both users and the AI agent to create, modify, and switch personalities. Based on research from OpenClaw, Cline Personas MCP, and LTM-CLINE.

## Design Principles

1. **Human-readable storage** - Markdown files (like current `SOUL.md`, `IDENTITY.md`)
2. **Agent-modifiable** - Via dedicated tool
3. **User-editable** - Direct file editing supported
4. **Session-scoped** - Per-session persona override capability
5. **Simple file-based** - No database needed

## Architecture

```
workspace/
├── personas/
│   ├── default/                 # Default persona (migrated from root)
│   │   ├── SOUL.md
│   │   ├── IDENTITY.md
│   │   └── AGENTS.md
│   ├── coder/                   # Example: coder persona
│   │   ├── SOUL.md
│   │   └── IDENTITY.md
│   └── writer/                  # Example: writer persona
│       ├── SOUL.md
│       └── IDENTITY.md
├── memory/
│   └── persona_state.json       # Active persona per session
└── AGENTS.md                    # (deprecated, move to personas/default/)
```

## Components

### 1. PersonaManager

```nim
type
  Persona* = object
    name*: string
    slug*: string           # directory name
    soul*: string           # content of SOUL.md
    identity*: string       # content of IDENTITY.md
    agents*: string         # content of AGENTS.md
    user*: string           # content of USER.md
    metadata*: PersonaMetadata

  PersonaMetadata* = object
    model*: string          # optional model override
    temperature*: float64   # optional temp override
    enabledTools*: seq[string] # tool whitelist
    createdAt*: int64
    updatedAt*: int64

  PersonaManager* = ref object
    personasDir*: string
    activePersonas*: Table[string, string]  # sessionKey -> personaSlug
```

### 2. PersonaTool

Tool for agent to manage personas:

```nim
methods:
- list_personas() -> List available personas
- get_persona(name) -> Get persona details
- create_persona(name, soul, identity) -> Create new persona
- update_persona(name, field, content) -> Update persona file
- switch_persona(name) -> Switch active persona for session
- delete_persona(name) -> Remove persona
```

### 3. ContextBuilder Integration

```nim
proc buildSystemPrompt(cb: ContextBuilder, sessionKey: string = ""): string =
  # Get active persona for session (or default)
  let persona = cb.personaManager.getActivePersona(sessionKey)
  # Include persona content in system prompt
```

### 4. TUI Commands

```
/persona                    - Show active persona
/persona list               - List all personas
/persona switch <name>      - Switch to persona
/persona create <name>      - Create new persona (interactive)
/persona edit <name>        - Edit persona file
/persona delete <name>      - Delete persona
```

## Implementation Phases

### Phase 1: PersonaManager Core (P0)

**Files:**
- `src/nimclaw/persona/manager.nim` (new)

**Tasks:**
1. Define `Persona`, `PersonaMetadata` types
2. Implement `loadPersona(slug)` - read from `workspace/personas/<slug>/`
3. Implement `savePersona(persona)` - write to directory
4. Implement `listPersonas()` - scan directories
5. Implement `getActivePersona(sessionKey)` - with fallback to default
6. Migration: Copy root `SOUL.md` etc. to `personas/default/`

**Timeline:** 1 day

### Phase 2: PersonaTool (P0)

**Files:**
- `src/nimclaw/tools/persona.nim` (new)
- `src/nimclaw/agent/loop.nim` (register tool)

**Tasks:**
1. Create `PersonaTool` with methods:
   - `list_personas`: List available personas
   - `get_persona`: Get specific persona content
   - `create_persona`: Create new persona (fills template)
   - `update_persona`: Update persona fields (soul/identity/agents)
   - `switch_persona`: Switch active for current session
2. Register tool in AgentLoop
3. Add to tool summaries

**Timeline:** 1 day

### Phase 3: ContextBuilder Integration (P0)

**Files:**
- `src/nimclaw/agent/context.nim`

**Tasks:**
1. Add `personaManager` to ContextBuilder
2. Update `buildSystemPrompt()` to include active persona
3. Update `loadBootstrapFiles()` to use persona paths

**Timeline:** 0.5 day

### Phase 4: TUI Commands (P1)

**Files:**
- `src/nimclaw/tui/core.nim`

**Tasks:**
1. Add `/persona` command parser
2. Implement subcommands:
   - `/persona` - show active
   - `/persona list` - list all
   - `/persona switch <name>` - switch
   - `/persona create <name>` - interactive create
3. Show active persona in TUI header

**Timeline:** 1 day

### Phase 5: Migration & Polish (P1)

**Files:**
- `src/nimclaw.nim` (onboard)
- `src/nimclaw/session.nim` (store active persona)

**Tasks:**
1. Update `onboard()` to create `personas/default/` with templates
2. Migrate existing `SOUL.md` etc. to new location
3. Store active persona in session metadata
4. Persist across restarts

**Timeline:** 0.5 day

## Template for New Personas

```markdown
# SOUL.md
I am {{name}}, a {{role}}.

## Personality
{{personality_traits}}

## Communication Style
{{communication_style}}

## Values
{{values}}
```

```markdown
# IDENTITY.md
# Identity

Name: {{name}} {{emoji}}
Role: {{role}}
Background: {{background}}
```

```markdown
# AGENTS.md
# Agent Instructions

You are a helpful AI assistant with the following specialties:
{{specialties}}

## Guidelines
{{guidelines}}
```

## Tool Schemas

### list_personas
```json
{
  "name": "list_personas",
  "description": "List all available personas"
}
```

### get_persona
```json
{
  "name": "get_persona",
  "description": "Get details of a specific persona",
  "parameters": {
    "name": {"type": "string", "description": "Persona name/slug"}
  }
}
```

### create_persona
```json
{
  "name": "create_persona",
  "description": "Create a new persona",
  "parameters": {
    "name": {"type": "string", "description": "Persona name"},
    "soul": {"type": "string", "description": "Personality description (SOUL.md content)"},
    "identity": {"type": "string", "description": "Identity info (IDENTITY.md content)"}
  }
}
```

### update_persona
```json
{
  "name": "update_persona",
  "description": "Update a persona field",
  "parameters": {
    "name": {"type": "string", "description": "Persona name"},
    "field": {"type": "string", "enum": ["soul", "identity", "agents"]},
    "content": {"type": "string", "description": "New content"}
  }
}
```

### switch_persona
```json
{
  "name": "switch_persona",
  "description": "Switch to a different persona for this session",
  "parameters": {
    "name": {"type": "string", "description": "Persona name to switch to"}
  }
}
```

## Success Criteria

- [ ] Can create persona via tool call
- [ ] Can update persona via tool call
- [ ] Can switch persona via tool call
- [ ] Can list personas via TUI command
- [ ] Persona persists per session
- [ ] Default persona loaded from `personas/default/`
- [ ] Backward compatible with existing setups

## Timeline Summary

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 1: Manager | 1 day | 1 day |
| Phase 2: Tool | 1 day | 2 days |
| Phase 3: Context | 0.5 day | 2.5 days |
| Phase 4: TUI | 1 day | 3.5 days |
| Phase 5: Migration | 0.5 day | 4 days |

**Total: ~4 days for full implementation**
