# Per-Session Management Implementation Plan

## Overview

This plan addresses the gap between Nimclaw's current basic session storage and PicoClaw's sophisticated session-per-conversation model. The goal is to make each session a self-contained, manageable unit with its own persona, memory, and lifecycle.

## Current State

```
Session (flat JSON)
├── key: string
├── messages: seq[Message]
├── summary: string
├── created: float64
└── updated: float64
```

Problems:
- No metadata about message provenance
- Cannot branch/undo from mid-conversation
- No per-session persona override
- Single summary string loses structure
- No checkpointing for crash recovery

## Target Architecture

```
Session (record-based JSONL)
├── key: string
├── created: float64
├── updated: float64
├── persona: PersonaConfig      # NEW: per-session persona override
├── records: seq[SessionRecord] # NEW: structured with metadata
├── checkpoints: seq<Checkpoint># NEW: save points for recovery
└── facts: seq<string>          # NEW: extracted user facts

SessionRecord
├── kind: enum {User, Assistant, Tool, System, Summary}
├── timestamp: int64
├── content: string
├── synthetic: bool             # true for summaries/injected content
├── toolCalls: seq<ToolCall>    # for assistant records
├── toolCallId: string          # for tool responses
└── metadata: Table[string,string] # extensible

Checkpoint
├── iteration: int
├── turn: int
├── messages: seq<Message>
├── pendingToolCalls: seq<ToolCall>
└── createdAt: int64
```

## Implementation Phases

### Phase 1: Record-Based Session Storage (P0)

**Goal:** Replace flat JSON with structured JSONL records.

**Tasks:**

1. **Define new types** (`src/nimclaw/session.nim`)
   ```nim
   type
     RecordKind* = enum rkUser, rkAssistant, rkTool, rkSystem, rkSummary
     
     SessionRecord* = object
       kind*: RecordKind
       timestamp*: int64
       content*: string
       synthetic*: bool
       toolCalls*: seq[StoredToolCall]
       toolCallId*: string
       name*: string
       metadata*: Table[string, string]
   ```

2. **Migrate SessionManager**
   - Change storage format from `.json` to `.jsonl`
   - Append-only write pattern (safer)
   - Backward-compatible migration on load

3. **Update ContextBuilder**
   - Build messages from records instead of flat history
   - Filter synthetic records appropriately

4. **Add `popRecord()` operation**
   - Remove last N records (for undo)
   - Wire to TUI keybinding (`Ctrl+U`)

**Files:**
- `src/nimclaw/session.nim`
- `src/nimclaw/agent/context.nim`
- `src/nimclaw/tui/core.nim`

**Timeline:** 1-2 days

---

### Phase 2: Per-Session Persona (P0)

**Goal:** Allow each session to have its own personality/prompt overrides.

**Tasks:**

1. **Add PersonaConfig type**
   ```nim
   type
     PersonaConfig* = object
       name*: string
       systemPrompt*: string
       model*: string           # override default model
       temperature*: float64    # override default temp
       maxTokens*: int
       enabledTools*: seq[string] # tool whitelist for this session
   ```

2. **Extend Session type**
   - Add `persona: PersonaConfig` field
   - Use global defaults if not set

3. **TUI commands**
   - `/persona <name>` - switch persona
   - `/persona list` - list available personas
   - `/persona reset` - back to default

4. **Persona storage**
   - `workspace/personas/<name>.md` - persona definitions
   - Load on startup

**Files:**
- `src/nimclaw/session.nim`
- `src/nimclaw/agent/context.nim`
- `src/nimclaw/tui/core.nim`

**Timeline:** 1-2 days

---

### Phase 3: Checkpointing (P1)

**Goal:** Save and resume agent loop state mid-conversation.

**Tasks:**

1. **Define Checkpoint type**
   ```nim
   type
     Checkpoint* = object
       sessionKey*: string
       iteration*: int
       turn*: int
       messages*: seq[Message]
       pendingToolCalls*: seq<ToolCall]
       createdAt*: int64
   ```

2. **Save checkpoints**
   - Save before executing tool calls
   - Location: `workspace/checkpoints/<session_key>/<turn>_<iteration>.json`

3. **Resume from checkpoint**
   - On startup, check for orphaned checkpoints
   - Prompt user: "Resume interrupted session?"
   - Replay tool results or re-execute

4. **Cleanup**
   - Delete checkpoint on successful completion
   - Keep last N checkpoints per session (configurable)

**Files:**
- `src/nimclaw/agent/loop.nim`
- `src/nimclaw/session.nim`
- `src/nimclaw.nim`

**Timeline:** 2-3 days

---

### Phase 4: Fact Extraction (P2)

**Goal:** Automatically extract and recall user preferences.

**Tasks:**

1. **FactStore type**
   ```nim
   type
     Fact* = object
       namespace*: string    # "user", "project", "global"
       key*: string
       value*: string
       source*: string       # which session/turn
       confidence*: float    # 0.0-1.0
       timestamp*: int64
     
     FactStore* = ref object
       path*: string         # workspace/memory/facts.jsonl
       facts*: seq<Fact>
   ```

2. **Extraction prompt**
   - After assistant turn, run extraction:
   - "Extract explicit user preferences from this conversation"
   - Parse bullet points into facts

3. **Fact injection**
   - Load relevant facts at session start
   - Add to system prompt as "User Preferences"

4. **TUI commands**
   - `/facts` - list known facts about user
   - `/forget <key>` - remove a fact

**Files:**
- `src/nimclaw/memory/fact_store.nim` (new)
- `src/nimclaw/agent/context.nim`
- `src/nimclaw/agent/loop.nim`

**Timeline:** 2-3 days

---

### Phase 5: Context Strategies (P2)

**Goal:** Configurable windowing and summarization strategies.

**Tasks:**

1. **ContextStrategy type**
   ```nim
   type
     ContextStrategy* = enum
       csFullHistory,      # Keep everything (until token limit)
       csLastNTurns,       # Keep only last N turns
       csSummarizeOld,     # Summarize older turns
       csRagRetrieval      # Embed and retrieve relevant
     
     StrategyConfig* = object
       strategy*: ContextStrategy
       maxTurns*: int
       keepLastNTurns*: int
       maxTokens*: int
   ```

2. **Implement strategies**
   - `csFullHistory`: Current behavior
   - `csLastNTurns`: Drop old turns
   - `csSummarizeOld`: Compress old turns to summary
   - `csRagRetrieval`: Future - vector search

3. **Per-session config**
   - Store strategy in session metadata
   - `/strategy <name>` command in TUI

**Files:**
- `src/nimclaw/agent/context.nim`

**Timeline:** 2 days

---

## TUI Commands to Add

| Command | Phase | Description |
|---------|-------|-------------|
| `Ctrl+U` | 1 | Undo last turn (pop last 2 records) |
| `/persona <name>` | 2 | Switch session persona |
| `/persona list` | 2 | List available personas |
| `/checkpoint` | 3 | Manual checkpoint save |
| `/resume` | 3 | Show resumable sessions |
| `/facts` | 4 | List known user facts |
| `/forget <key>` | 4 | Remove a fact |
| `/strategy <name>` | 5 | Set context strategy |
| `/session info` | 1 | Show session metadata |
| `/session rename <name>` | 1 | Rename session |

## Storage Layout

```
workspace/
├── sessions/
│   ├── tui:default:1.jsonl      # NEW: JSONL format
│   └── telegram:chat123.jsonl
├── checkpoints/
│   └── tui:default:1/
│       ├── 5_3.json              # turn 5, iteration 3
│       └── 8_1.json
├── personas/
│   ├── default.md
│   ├── coder.md
│   └── writer.md
└── memory/
    ├── MEMORY.md
    ├── facts.jsonl               # NEW: extracted facts
    └── 202604/
        └── 20260404.md
```

## Migration Strategy

1. On load, detect old `.json` format
2. Convert to new `.jsonl` format
3. Keep `.json` as backup (`.json.bak`)
4. New sessions use `.jsonl` natively

## Configuration

```json
{
  "session": {
    "max_sessions": 100,
    "max_age_days": 30,
    "checkpoint_enabled": true,
    "fact_extraction_enabled": true,
    "default_strategy": "summarize_old",
    "context": {
      "max_turns": 50,
      "keep_last_n": 4,
      "max_tokens": 8000
    }
  }
}
```

## Success Criteria

- [ ] Can undo last turn with `Ctrl+U`
- [ ] Can switch persona mid-session
- [ ] Can resume crashed tool loop
- [ ] Facts are extracted and recalled automatically
- [ ] Old sessions are migrated transparently
- [ ] Context strategy is configurable per session

## Timeline Summary

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 1: Records | 1-2 days | 2 days |
| Phase 2: Persona | 1-2 days | 4 days |
| Phase 3: Checkpoints | 2-3 days | 7 days |
| Phase 4: Facts | 2-3 days | 10 days |
| Phase 5: Strategies | 2 days | 12 days |

**Total: ~2 weeks for full implementation**
