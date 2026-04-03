# Session Management Plan for Nimclaw

## 1. Problem Statement

Nimclaw currently stores conversation state in flat JSON files (`workspace/sessions/<key>.json`). Each session contains:

- `history`: a linear sequence of `Message` objects
- `summary`: a single compressed string

This works for simple demos, but it lacks the sophistication expected of a production agent CLI:

- **No checkpointing**: we cannot resume a crashed tool loop mid-iteration.
- **No time-travel**: we cannot branch from an earlier turn or undo a bad tool call.
- **No dual-memory model**: everything lives in one linear blob; there is no distinction between "this conversation" and "facts I should remember about the user forever".
- **Limited summarization**: we truncate to the last 4 messages and replace the rest with one summary. We lose tool-call structure and cannot reconstruct exact state.
- **No metadata**: messages are not tagged as `synthetic`, `user`, `tool`, etc., making summarization and observability hard.

## 2. How Other Frameworks Manage Sessions

### 2.1 OpenAI Agents SDK

**Core abstraction:** `Session` (backed by `SQLiteSession`, `RedisSession`, `SQLAlchemySession`, `DaprSession`, `EncryptedSession`, etc.)

- A **thread** maps 1:1 to a session ID.
- `get_items()` returns model-safe messages (no metadata).
- `add_items()` persists new turns; can trigger **summarization** when `context_limit` is exceeded.
- `pop_item()` enables "undo" / correction flows.
- `session_input_callback` lets the runner customize how history merges with new input *without* mutating what is stored.
- **Compaction sessions** (`OpenAIResponsesCompactionSession`) use the Responses API to compact history into a smaller synthetic turn.

**Key insight:** Storage and retrieval are separate concerns. The session is a dumb key-value store for conversation items; the *runner* decides how to window, summarize, or filter them before sending to the model.

### 2.2 LangGraph / LangChain

**Core abstractions:**

1. **Checkpointer** — short-term, thread-scoped memory
2. **Store** — long-term, cross-thread knowledge

#### Checkpointers (`SqliteSaver`, `PostgresSaver`, `RedisSaver`, `MongoDBSaver`, `MemorySaver`)

- Save a **snapshot of the full graph state** after every *super-step* (after all parallel nodes finish).
- Identified by `thread_id`.
- Enables:
  - **Resume** after crash or human-in-the-loop pause
  - **Replay / time-travel** — branch from any past checkpoint
  - **Observability** — inspect exact state at every step

#### Store (`MongoDBStore`, `RedisStore`)

- Hierarchical namespace key-value storage.
- Optional semantic search via embeddings.
- Used for **user preferences**, **learned facts**, **shared knowledge** that should survive across threads.

**Key insight:** Separating *execution state* (checkpoints) from *semantic memory* (store) lets you optimize each layer independently. Checkpoints are large, frequent, and ephemeral; stores are small, curated, and durable.

### 2.3 CrewAI

**Four-layer memory architecture:**

| Layer | Backend | Purpose |
|-------|---------|---------|
| Short-term | ChromaDB + RAG | Current session context |
| Long-term | SQLite3 | Insights and task results across sessions |
| Entity | ChromaDB + RAG | Structured facts about people, places, concepts |
| Contextual | Composite | Merged view of the above |

- Short-term memory is **RAG-based**, not just a raw message list. Older turns are embedded and retrieved on demand rather than kept verbatim in context.
- Long-term memory stores explicit facts extracted from task outputs.

**Key insight:** You do not have to keep every old message in the prompt. You can vectorize them and retrieve only the relevant ones, trading exact replay for context-window efficiency.

### 2.4 Summary of Patterns

| Framework | Unit of Isolation | Persistence Granularity | Context-Length Strategy | Long-Term Memory |
|-----------|-------------------|-------------------------|------------------------|------------------|
| OpenAI SDK | `thread_id` | Per-message items | Summarizing / compaction sessions | None built-in |
| LangGraph | `thread_id` | Per-super-step checkpoints | Full replay + manual windowing | `Store` (KV + semantic) |
| CrewAI | Session / task | RAG chunks + SQLite facts | Retrieval-augmented injection | SQLite + vector DB |

## 3. Design Goals for Nimclaw

We want to evolve Nimclaw’s session layer incrementally while keeping the codebase small and native-Nim. We propose **three phases**:

### Phase 1: Structured Session Store (Immediate)

Replace the flat JSON file with a **record-based** session file that preserves metadata and turn boundaries.

**New `SessionRecord` type:**

```nim
type
  RecordKind* = enum
    rkUser, rkAssistant, rkTool, rkSystem, rkSummary

  SessionRecord* = object
    kind*: RecordKind
    synthetic*: bool        # true for summaries, injected prompts, etc.
    timestamp*: int64
    content*: string
    toolCalls*: seq[ToolCall]
    toolCallId*: string
    name*: string           # tool name or agent name
```

**Changes:**

- `Session` stores `records: seq[SessionRecord]` instead of `history: seq[Message]`.
- `SessionManager` reads/writes records as JSON lines (`.jsonl`) for append-only safety.
- `ContextBuilder` builds `messages` from records on demand, filtering out metadata.
- Add `popRecord()` to the session manager so the TUI can support "undo last turn".

**Benefits:**
- Exact message provenance is preserved.
- Summaries become explicit `rkSummary` records, not a single shadow string.
- We can later reconstruct full state or replay from any turn.

### Phase 2: Checkpointing the Agent Loop (Medium-Term)

Persist the agent loop’s **execution state** after every iteration, not just the final result.

**Checkpoint schema:**

```nim
type
  Checkpoint* = object
    sessionKey*: string
    iteration*: int
    turn*: int              # which user turn this checkpoint belongs to
    messages*: seq[Message] # full message list sent to LLM up to this point
    pendingToolCalls*: seq[ToolCall]  # tool calls awaiting execution
    createdAt*: int64
```

**Implementation:**

- Save a checkpoint to `workspace/checkpoints/<session_key>/<turn>_<iteration>.json` immediately after receiving the LLM response and before executing tools.
- On startup, if a checkpoint exists for the current session and the previous run did not finish, prompt the user (or auto-resume) from that checkpoint.
- If all tools in a checkpoint succeed, delete it (or archive it). If the process crashed, resume from the checkpoint, re-run tools, and continue.

**Benefits:**
- Crash recovery inside long tool chains (e.g., 20 iterations).
- Foundation for "time-travel" debugging: inspect or branch from any iteration.

### Phase 3: Dual Memory — Short-Term + Long-Term (Long-Term)

Introduce two distinct storage layers, similar to LangGraph:

#### 3a. Short-Term: Summarizing Sessions

Enhance `ContextBuilder` with configurable **windowing** and **summarization** strategies:

```nim
type
  ContextStrategy* = object
    maxTurns*: int          # max real user turns before summarizing
    keepLastNTurns*: int    # verbatim turns to preserve
    maxTokens*: int         # token budget for context window
```

- When `maxTurns` is exceeded, summarize everything before the earliest of the last `keepLastNTurns` turns into a synthetic `rkSummary` record.
- The summarizer is itself an LLM call (reuse `AgentLoop.summarizeBatch`).
- The strategy is configurable per-session or globally.

#### 3b. Long-Term: Simple Fact Store

Add a `FactStore` keyed by namespace:

```nim
type
  FactStore* = ref object
    path*: string           # workspace/memory/facts.jsonl

proc put*(store: FactStore, namespace, key, value: string)
proc get*(store: FactStore, namespace, key: string): Option[string]
proc search*(store: FactStore, namespace, query: string): seq[string]
```

- After every assistant turn, run a lightweight extraction prompt:
  *"Extract any explicit user preferences or facts from this conversation. Output as bullet points: `- <key>: <value>`"*
- Parse the output and write facts to the store under the `user` namespace.
- Inject the most relevant facts into the system prompt (or as a `rkSystem` record) at the start of each new session.

**Storage options:**
- Phase 3.1: Flat JSONL file (good enough for local CLI usage).
- Phase 3.2: SQLite FTS table if search volume grows.
- Phase 3.3: Optional embedding-based retrieval if users ask for semantic memory.

## 4. Migration Path

1. **Backward compatibility**: keep the existing `Session` type as `LegacySession` and write a one-time migrator that converts old `.json` session files into the new `.jsonl` record format.
2. **No breaking changes to the TUI**: the TUI only interacts with `AgentLoop.processDirect()`. All session changes stay behind `SessionManager` and `ContextBuilder`.
3. **Optional features**: checkpointing and fact stores can be disabled via `config.nims` or `nimclaw.cfg` flags so lightweight deployments are not penalized.

## 5. Recommended Next Steps

| Priority | Task | Files to Touch |
|----------|------|----------------|
| P0 | Define `SessionRecord` and migrate `Session` / `SessionManager` | `src/nimclaw/session.nim`, `src/nimclaw/agent/context.nim` |
| P0 | Add `popRecord()` and wire it to a TUI keybinding (e.g., `Ctrl+U`) | `src/nimclaw/session.nim`, `src/nimclaw/tui/core.nim` |
| P1 | Implement checkpoint save/load in `AgentLoop.runLLMIteration` | `src/nimclaw/agent/loop.nim` |
| P1 | Add auto-resume prompt on TUI startup when a checkpoint exists | `src/nimclaw/tui/core.nim`, `src/nimclaw.nim` |
| P2 | Add `ContextStrategy` and turn-based summarization to `ContextBuilder` | `src/nimclaw/agent/context.nim` |
| P2 | Build `FactStore` with JSONL backend and fact-extraction prompt | `src/nimclaw/memory/fact_store.nim` |
| P3 | Inject top-K facts into system prompt per session | `src/nimclaw/agent/context.nim` |

## 6. References

- OpenAI Agents SDK — Sessions & Summarizing: https://openai.github.io/openai-agents-python/sessions/
- LangGraph — Persistence and Checkpointing: https://langchain-ai.github.io/langgraph/concepts/persistence/
- LangGraph — Memory (short-term vs long-term): https://langchain-ai.github.io/langgraph/concepts/memory/
- CrewAI — Memory Systems: https://docs.crewai.com/concepts/memory
