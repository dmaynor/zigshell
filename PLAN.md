# ZigShell Codegen Roadmap & Agent Prompt Pack

This document contains all phased prompts for building:

- ZigShell (core)
- ZigScript (systems scripting layer)
- Tool Schema Format (typed CLI ontology)
- Project Authority Envelope (capability model)
- AI Planning Protocol (constrained execution)
- Learning Engine (ranking-only)
- Research Mode (isolated pack generation)

This is structured for long-running codegen agent swarms.

Non-negotiable invariants apply to all phases:
- No string-based shell execution.
- No implicit authority.
- No AI auto-execution without validation.
- No schema mutation without human approval.
- All execution must use structured command objects.
- Capability enforcement happens in ZigShell core.


---

# PHASE 0 — Core Philosophy Lock

## Objective
Define architectural invariants and threat model before writing core logic.

## Deliverables
- ARCHITECTURE.md
- Directory layout
- Trust boundaries
- Authority model

## CODEGEN PROMPT

You are implementing the foundational invariants for ZigShell.

Constraints:
- Shell is written in Zig.
- All command execution must use structured Command objects.
- No string-based shell evaluation allowed.
- Authority must be capability-based and project-scoped.
- AI is advisory only and never executes directly.
- Tool schemas must be versioned and serializable (JSON/YAML).
- Learning mode must never auto-activate schema.

Deliver:

1. ARCHITECTURE.md
   - System overview
   - Invariant list
   - Threat model
   - Failure modes
   - Trust boundaries
   - Authority model
2. Directory structure layout for:
   - core/
   - vm/
   - schema/
   - ai/
   - packs/
   - policy/
   - research/

Be explicit. No speculative features.


---

# PHASE 1 — Tool Schema Format v0

## Objective
Create strict, typed schema format for CLI tools.

## Requirements
- Hierarchical subcommands
- Typed flags
- Typed positionals
- Constraint support
- Risk metadata
- Capability bindings
- Machine-validated

## CODEGEN PROMPT

Implement Tool Schema Format v0.

Requirements:
- Represent tool name, binary, version.
- Support hierarchical subcommands.
- Support positional args with types.
- Support flags with:
  - type (bool, string, int, float, enum, path)
  - required/optional
  - multiplicity
  - range constraints
  - regex constraints
- Support mutually exclusive groups.
- Support capability bindings.
- Support risk metadata.
- Schema must be serializable and deserializable.
- Provide schema validation logic.

Deliver:
1. schema/tool_schema.zig
2. JSON schema representation.
3. Validation engine.
4. 3 example schemas:
   - git.commit
   - docker.build
   - zig.build
5. Unit tests for validation.


---

# PHASE 2 — Structured Command Execution Engine

## Objective
Replace string-based execution with typed execution.

## CODEGEN PROMPT

Implement structured command execution engine.

Requirements:
- Define Command struct:
  - tool_id
  - resolved binary
  - args (typed)
  - cwd
  - env delta
  - requested capabilities
- Implement:
  - CommandBuilder from schema + AI parameters
  - Schema validation before execution
  - Capability check before execution
  - Execution wrapper using std.ChildProcess
- No string concatenation execution allowed.
- Execution must fail hard on validation error.

Deliver:
1. core/command.zig
2. core/executor.zig
3. Integration test: valid vs invalid command execution.


---

# PHASE 3 — Project Authority Envelope

## Objective
Implement per-project scoped authority.

## CODEGEN PROMPT

Implement Project Authority Envelope system.

Requirements:
- Load .zigshell/project.yaml
- Define authority levels:
  - Observe
  - ToolsOnly
  - ParameterizedTools
  - ScopedCommands
- Bind authority to:
  - allowed tool ids
  - filesystem root
  - network access
  - allowed binaries
- Implement AuthorityToken struct:
  - project_id
  - level
  - expiration
  - allowed_tools
  - allowed_bins
- Enforce authority in executor layer.
- Provide audit log entry for every denied execution.

Deliver:
1. policy/authority.zig
2. policy/loader.zig
3. policy/enforcer.zig
4. Example project config.


---

# PHASE 4 — Help Parser / Candidate Pack Generator (Research Mode)

## Objective
Generate candidate tool schemas from `--help` output.

## CODEGEN PROMPT

Implement help-based schema extractor (research mode only).

Requirements:
- Run binary with timeout.
- Try common help flags.
- Parse:
  - flags
  - subcommands
  - enum options
  - numeric ranges
- Produce candidate ToolSchema.
- Mark schema as untrusted.
- Save to packs/candidate/.
- DO NOT auto-activate.
- Hash binary and store fingerprint.

Deliver:
1. schema/help_parser.zig
2. schema/candidate_generator.zig
3. CLI command: zigshell pack generate <binary>
4. Example generated schema.


---

# PHASE 5 — AI Planning Protocol

## Objective
Constrain AI to structured output only.

## CODEGEN PROMPT

Define AI planning protocol.

Requirements:
- AI must output JSON only.
- Structure:
  - plan_id
  - steps[]
    - tool_id
    - params
    - justification
    - risk_score
    - capability_requests
- Validate AI output against schema.
- Reject if:
  - Unknown tool_id
  - Invalid parameters
  - Authority violation
- Provide dry-run mode.

Deliver:
1. ai/protocol.zig
2. ai/validator.zig
3. Example valid/invalid plan files.


---

# PHASE 6 — Learning Engine (Ranking Only)

## Objective
Learn usage patterns without modifying schema or authority.

## CODEGEN PROMPT

Implement learning subsystem.

Constraints:
- Must NOT modify tool schemas.
- Must NOT expand authority.
- Can store:
  - successful parameter combos
  - failure patterns
  - execution duration
  - exit codes
- Provide ranking score for AI suggestions.

Deliver:
1. ai/learning_store.zig
2. ai/ranker.zig
3. Audit trail for learned patterns.


---

# PHASE 7 — Unrestricted Research Mode (Isolated)

## Objective
Enable experimental pack evolution without authority mutation.

## CODEGEN PROMPT

Implement unrestricted research mode.

Requirements:
- Must require explicit flag: --research-mode
- Must display prominent terminal warning.
- Run in isolated profile.
- Can:
  - Observe PATH
  - Parse help
  - Generate candidate packs
- Cannot:
  - Activate packs
  - Modify restricted packs
  - Escalate authority
- Output only candidate pack diffs.

Deliver:
1. research/mode.zig
2. research/sandbox.zig
3. research/pack_diff.zig


---

# Dependency Order

Phase 0 → Phase 1 → Phase 2 → Phase 3  
Phase 4 depends on Phase 1  
Phase 5 depends on Phase 1, 2, 3  
Phase 6 depends on Phase 2  
Phase 7 depends on Phase 1 and Phase 4  

Never implement Phase 5 before Phase 2 is stable.

Never enable Research Mode before Authority Enforcement exists.

---

# Final Invariant

ZigShell is:

- A deterministic command execution engine
- With typed CLI schemas
- With capability-based authority
- With AI planning constrained by schema
- With learning limited to ranking
- With research mode isolated

Anything that violates these invariants is architectural drift.

