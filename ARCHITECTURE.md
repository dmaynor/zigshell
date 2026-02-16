# ZigShell Architecture

## System Overview

ZigShell is a deterministic command execution engine written in Zig. It replaces
traditional string-based shell evaluation with structured, typed command objects
validated against versioned tool schemas and enforced by a capability-based
authority model.

An optional AI planning layer can suggest command sequences, but all AI output
is treated as untrusted advisory input. Execution authority flows exclusively
from human-approved project configurations.

### Component Map

```
┌─────────────────────────────────────────────────────┐
│                      User / TUI                     │
├─────────────────────────────────────────────────────┤
│                   ZigShell Core                     │
│  ┌───────────┐  ┌───────────┐  ┌────────────────┐  │
│  │  Command   │  │  Schema   │  │   Authority    │  │
│  │  Builder   │  │  Engine   │  │   Enforcer     │  │
│  └─────┬─────┘  └─────┬─────┘  └───────┬────────┘  │
│        │              │                 │           │
│        ▼              ▼                 ▼           │
│  ┌─────────────────────────────────────────────┐    │
│  │             Structured Executor              │    │
│  │       (std.process.Child — no sh -c)         │    │
│  └─────────────────────────────────────────────┘    │
├─────────────────────────────────────────────────────┤
│              AI Advisory Layer (optional)            │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │  Planning   │  │  Learning  │  │  Research    │  │
│  │  Protocol   │  │  Ranker    │  │  Sandbox     │  │
│  └────────────┘  └────────────┘  └──────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## Architectural Invariants

These are non-negotiable. Violation of any invariant is an architectural defect.

| ID | Invariant | Enforcement Point |
|----|-----------|-------------------|
| INV-1 | No string-based shell execution | Executor: no `sh -c`, no string concat of args |
| INV-2 | All commands are structured `Command` objects | CommandBuilder: typed fields only |
| INV-3 | No implicit authority | Enforcer: every execution requires AuthorityToken |
| INV-4 | AI never executes directly | Protocol: AI produces plans, humans approve |
| INV-5 | Tool schemas are versioned and immutable once activated | Schema Engine: version + hash on load |
| INV-6 | Schema mutation requires human approval | Schema store: no programmatic write path |
| INV-7 | Learning engine cannot modify schemas or authority | Ranker: read-only access to schemas |
| INV-8 | Research mode is fully isolated | Sandbox: separate profile, no authority escalation |
| INV-9 | Every denied execution produces an audit entry | Enforcer: audit log on deny |
| INV-10 | Capability enforcement is in core, not plugins | Enforcer lives in core, not AI layer |

---

## Trust Boundaries

```
 TRUSTED                          UNTRUSTED
┌──────────────────────┐    ┌──────────────────────┐
│                      │    │                       │
│  Human operator      │    │  AI planning output   │
│  Project config      │    │  Candidate packs      │
│  Activated schemas   │    │  --help parse results  │
│  Authority tokens    │    │  Learning suggestions  │
│  Core executor       │    │  External binaries     │
│                      │    │  Environment variables  │
└──────────────────────┘    └──────────────────────┘
         │                           │
         ▼                           ▼
   ┌─────────────────────────────────────┐
   │        TRUST BOUNDARY (core)        │
   │  - Schema validation                │
   │  - Authority check                  │
   │  - Audit logging                    │
   └─────────────────────────────────────┘
         │
         ▼
   ┌─────────────────┐
   │  Execution zone  │
   │  (child process) │
   └─────────────────┘
```

### Boundary Rules

1. **Nothing crosses from UNTRUSTED to EXECUTION without passing through all three gates**: schema validation, authority check, audit log.
2. **AI output is always untrusted.** Even if the AI model is local, its output is treated identically to remote/adversarial input.
3. **Candidate packs (from research mode) remain untrusted** until a human explicitly activates them.
4. **External binary output is untrusted.** Exit codes and stdout/stderr are observable but never interpreted as commands.

---

## Authority Model

### Levels (ordered, non-inheriting)

| Level | Permits | Example |
|-------|---------|---------|
| `Observe` | Read project state, list tools | CI status dashboard |
| `ToolsOnly` | Run tools from approved list, no parameters | `git status`, `zig build` |
| `ParameterizedTools` | Run approved tools with validated parameters | `git commit -m "msg"` |
| `ScopedCommands` | Full parameterized execution within filesystem/network scope | `docker build -t myapp .` |

### AuthorityToken

```
AuthorityToken {
    project_id:    [32]u8          // SHA-256 of project root
    level:         AuthorityLevel
    expiration:    i64             // Unix timestamp, 0 = session
    allowed_tools: []ToolId
    allowed_bins:  [][]const u8
    fs_root:       []const u8     // Filesystem jail
    network:       NetworkPolicy   // deny | localhost | allowlist
}
```

### Enforcement Flow

```
Command arrives
  → Schema valid?        NO → DENY + audit
  → Authority loaded?    NO → DENY + audit
  → Tool in allow list?  NO → DENY + audit
  → Params in bounds?    NO → DENY + audit
  → Binary in allow list? NO → DENY + audit
  → CWD under fs_root?  NO → DENY + audit
  → EXECUTE
  → Log result
```

---

## Threat Model

### Threats and Mitigations

| ID | Threat | Impact | Mitigation |
|----|--------|--------|------------|
| T-1 | AI injects shell metacharacters | Arbitrary code execution | INV-1: No string-based execution. Args are array elements, never concatenated. |
| T-2 | AI requests tool outside authority | Unauthorized system access | INV-3: AuthorityToken.allowed_tools checked before execution. |
| T-3 | Malicious tool schema activated | Incorrect validation allows bad args | INV-6: Human approval required. Schema hash verified on load. |
| T-4 | Learning engine poisons suggestions | User executes harmful command | INV-7: Learning is ranking-only. Human still approves every execution. |
| T-5 | Research mode escapes sandbox | Authority escalation | INV-8: Separate profile. Cannot write to activated pack store. |
| T-6 | Binary path traversal | Execute unexpected binary | Authority enforcer resolves and checks binary against allow list. |
| T-7 | Environment variable injection | Modify execution behavior | Command.env_delta is explicit; inherited env is auditable. |
| T-8 | Schema version downgrade | Bypass newer constraints | Schema engine rejects loading older version if newer is activated. |
| T-9 | Time-of-check/time-of-use on binary | Binary swapped after check | Hash binary at schema generation time. Re-verify before exec (optional, configurable). |
| T-10 | Denial of service via fork bomb | System resource exhaustion | Executor applies resource limits (timeout, memory cap) per execution. |

---

## Failure Modes

| Failure | Behavior | Recovery |
|---------|----------|----------|
| Schema file corrupt/missing | Refuse to load tool. Log error. | User re-installs pack. |
| Authority config missing | Default to `Observe` (no execution). | User creates `.zigshell/project.yaml`. |
| Authority config malformed | Refuse to load. Default to `Observe`. | User fixes config. |
| AI plan references unknown tool | Reject plan. Return structured error. | AI retries or user intervenes. |
| AI plan violates authority | Reject violating steps. Allow valid ones if independent. | User escalates authority or modifies plan. |
| Binary not found in PATH | Execution fails with clear error. | User installs binary or updates config. |
| Executor timeout | Kill child process. Log timeout. | User re-runs with higher limit or investigates. |
| Disk full during audit log | Halt execution (audit is mandatory per INV-9). | User frees space. |
| Learning store corrupt | Disable ranking. Fall back to unranked. | User resets learning store. |

---

## Directory Layout

```
zigshell/
├── build.zig                # Zig build configuration
├── build.zig.zon            # Package manifest
├── ARCHITECTURE.md          # This document
├── PLAN.md                  # Codegen roadmap
│
├── src/
│   ├── main.zig             # Entry point
│   │
│   ├── core/                # Structured execution engine
│   │   ├── command.zig      # Command struct and builder
│   │   └── executor.zig     # Child process execution
│   │
│   ├── schema/              # Tool schema format
│   │   ├── tool_schema.zig  # Schema types and validation
│   │   ├── help_parser.zig  # --help output parser
│   │   └── candidate.zig    # Candidate pack generator
│   │
│   ├── policy/              # Authority and capability
│   │   ├── authority.zig    # AuthorityToken and levels
│   │   ├── loader.zig       # Project config loader
│   │   └── enforcer.zig     # Capability enforcement
│   │
│   ├── ai/                  # AI advisory layer
│   │   ├── protocol.zig     # Planning protocol (JSON)
│   │   ├── validator.zig    # Plan validation
│   │   ├── learning.zig     # Usage pattern storage
│   │   └── ranker.zig       # Suggestion ranking
│   │
│   ├── vm/                  # ZigScript VM (future)
│   │
│   └── research/            # Isolated research mode
│       ├── mode.zig         # Research mode entry
│       ├── sandbox.zig      # Isolation enforcement
│       └── pack_diff.zig    # Candidate pack diffing
│
├── packs/                   # Tool schema packs
│   ├── activated/           # Human-approved schemas
│   └── candidate/           # Untrusted generated schemas
│
└── test/                    # Integration tests
```

---

## Design Decisions

### Why no `sh -c`?
String-based shell execution is the primary vector for injection attacks in
AI-assisted tools. By requiring structured `Command` objects with typed argument
arrays, we eliminate the entire class of shell metacharacter attacks. The
executor calls `std.process.Child` directly with an argument array.

### Why capability-based authority?
Role-based access is too coarse. A project that needs `git commit` should not
automatically get `git push`. Capability-based authority lets operators grant
exactly the tools and parameters needed, nothing more.

### Why is AI advisory-only?
An AI model that can execute commands without validation is an uncontrolled
escalation path. By treating all AI output as untrusted structured data, we
maintain the human as the authority boundary regardless of model capability.

### Why ranking-only learning?
A learning system that modifies schemas or authority is a slow privilege
escalation. By limiting learning to ranking (which suggestions appear first),
we get UX improvement without security regression.
