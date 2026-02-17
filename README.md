# ZigShell

A deterministic command execution engine written in Zig that replaces traditional string-based shell evaluation with structured, typed command objects.

## Overview

ZigShell is a security-focused shell that:

- Eliminates shell injection vulnerabilities through structured command objects
- Enforces capability-based authority for command execution
- Validates commands against versioned tool schemas
- Treats AI suggestions as untrusted advisory input
- Provides full audit logging of all command execution

### Key Features

- **No String-Based Execution**: All commands are structured objects, eliminating shell metacharacter injection attacks
- **Capability-Based Authority**: Fine-grained control over which tools and parameters can be executed
- **Versioned Tool Schemas**: Typed command-line interfaces with validation
- **AI Advisory Layer**: Optional AI planning that requires human approval
- **Learning Engine**: Ranks suggestions based on usage patterns without modifying schemas
- **Research Mode**: Isolated environment for experimental schema generation

## Installation

### Prerequisites

- Zig compiler (version 0.11 or later)

### Building from Source

```bash
git clone https://github.com/dmaynor/zigshell.git
cd zigshell
zig build
```

The binary will be available at `zig-out/bin/zigshell`.

### Running

```bash
# Show help
./zig-out/bin/zigshell --help

# Show version
./zig-out/bin/zigshell --version

# Run interactive shell
./zig-out/bin/zigshell shell
```

## Usage

### Interactive Shell Mode

Start the interactive REPL:

```bash
zigshell shell
```

In shell mode, you can execute commands that are validated against loaded tool schemas and your project's authority configuration.

### Command Validation

Validate an AI-generated plan without executing it:

```bash
zigshell validate plan.json
```

### Command Execution

Execute a validated AI plan:

```bash
zigshell exec plan.json
```

### Project Information

View your project's authority configuration and loaded schemas:

```bash
zigshell info
```

Example output:
```
zigshell v0.1.0

Project root: /home/user/myproject
Authority level: ParameterizedTools
Network policy: localhost
Filesystem root: /home/user/myproject
Allowed tools: 5
Allowed bins: 3

Schemas loaded: 3
Load failures: 0
```

### Schema Management

List all activated tool schemas:

```bash
zigshell schemas
```

List activated schema packs:

```bash
zigshell pack list
```

Generate a candidate schema from a binary's help output:

```bash
zigshell pack generate <binary>
```

This will:
1. Capture the binary's `--help` output
2. Parse flags, subcommands, and options
3. Generate a candidate schema
4. Save it to `packs/candidate/<binary>.json`

**Note**: Candidate schemas are untrusted. Review them carefully before copying to `packs/activated/` to enable them.

## Architecture

### Core Components

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

### Authority Levels

ZigShell enforces one of four authority levels per project:

| Level | Permits | Example |
|-------|---------|---------|
| `Observe` | Read project state, list tools | CI status dashboard |
| `ToolsOnly` | Run tools from approved list, no parameters | `git status`, `zig build` |
| `ParameterizedTools` | Run approved tools with validated parameters | `git commit -m "msg"` |
| `ScopedCommands` | Full parameterized execution within filesystem/network scope | `docker build -t myapp .` |

### Directory Structure

```
zigshell/
├── packs/                   # Tool schema packs
│   ├── activated/           # Human-approved schemas
│   │   ├── git.commit.json
│   │   ├── zig.build.json
│   │   └── docker.build.json
│   └── candidate/           # Untrusted generated schemas
├── .zigshell/               # Project configuration
│   └── project.yaml         # Authority configuration
└── src/                     # Source code
    ├── core/                # Command execution engine
    ├── schema/              # Tool schema format
    ├── policy/              # Authority and capability
    ├── ai/                  # AI advisory layer
    ├── shell/               # Interactive REPL
    └── research/            # Isolated research mode
```

## Configuration

### Project Authority

Create `.zigshell/project.yaml` in your project root:

```yaml
authority_level: ParameterizedTools
network: localhost
allowed_tools:
  - git.commit
  - git.status
  - zig.build
allowed_binaries:
  - /usr/bin/git
  - /usr/bin/zig
filesystem_root: /home/user/myproject
```

### Tool Schemas

Tool schemas define the structure and constraints of command-line tools. They are stored as JSON files in `packs/activated/`.

Example schema (`git.commit.json`):

```json
{
  "id": "git.commit",
  "name": "git commit",
  "binary": "git",
  "version": 1,
  "risk": "local_write",
  "capabilities": ["vcs.write"],
  "flags": [
    {
      "name": "message",
      "short": 109,
      "arg_type": "string",
      "required": true,
      "description": "Commit message"
    },
    {
      "name": "all",
      "short": 97,
      "arg_type": "bool",
      "required": false,
      "description": "Stage all modified and deleted files"
    }
  ],
  "positionals": [],
  "subcommands": [],
  "exclusive_groups": []
}
```

## Security

### Architectural Invariants

ZigShell maintains these non-negotiable security invariants:

1. **No string-based shell execution** - No `sh -c`, no string concatenation of args
2. **All commands are structured objects** - Typed fields only
3. **No implicit authority** - Every execution requires an AuthorityToken
4. **AI never executes directly** - AI produces plans, humans approve
5. **Tool schemas are versioned** - Immutable once activated
6. **Schema mutation requires human approval** - No programmatic write path
7. **Learning cannot modify schemas or authority** - Read-only access
8. **Research mode is fully isolated** - Separate profile, no authority escalation
9. **Every denied execution produces an audit entry** - Mandatory logging
10. **Capability enforcement is in core** - Not in plugins

### Trust Boundaries

```
 TRUSTED                          UNTRUSTED
┌──────────────────────┐    ┌──────────────────────┐
│ Human operator       │    │ AI planning output   │
│ Project config       │    │ Candidate packs      │
│ Activated schemas    │    │ --help parse results │
│ Authority tokens     │    │ Learning suggestions │
│ Core executor        │    │ External binaries    │
└──────────────────────┘    └──────────────────────┘
```

All untrusted input passes through:
1. Schema validation
2. Authority check
3. Audit logging

before execution.

## Development

### Building

```bash
zig build
```

### Running Tests

```bash
zig build test
```

### Project Structure

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed architectural documentation.

See [PLAN.md](PLAN.md) for the development roadmap.

## Examples

### Example 1: Committing Code

```bash
# In shell mode
zigshell shell
> git.commit --message "Add feature X" --all

# Or via a plan file
cat > plan.json << 'EOF'
{
  "plan_id": "commit-feature-x",
  "steps": [
    {
      "tool_id": "git.commit",
      "params": [
        {"name": "message", "value": "Add feature X"},
        {"name": "all", "value": "true"}
      ],
      "positionals": [],
      "justification": "Commit changes",
      "risk_score": 0.3,
      "capability_requests": ["vcs.write"]
    }
  ]
}
EOF

zigshell validate plan.json
zigshell exec plan.json
```

### Example 2: Building a Project

```bash
# In shell mode
zigshell shell
> zig.build

# Or directly
zigshell exec zig-build-plan.json
```

### Example 3: Generating a Schema

```bash
# Generate schema for a new tool
zigshell pack generate docker

# Review the generated schema
cat packs/candidate/docker.json

# After review, activate it
cp packs/candidate/docker.json packs/activated/

# Verify it's loaded
zigshell schemas
```

## FAQ

### Why not just use bash/zsh?

Traditional shells execute commands via string evaluation, which is vulnerable to injection attacks when used with AI or untrusted input. ZigShell uses structured command objects that eliminate this entire class of vulnerabilities.

### Can I use ZigShell as my daily shell?

ZigShell is designed primarily for secure command execution in AI-assisted and automated contexts. While it has an interactive mode, it's not intended to replace your daily shell.

### How does the AI integration work?

ZigShell treats all AI output as untrusted. The AI generates structured plans in JSON format, which are validated against tool schemas and authority policies before execution. The human operator must explicitly approve execution.

### What happens if a command is denied?

The command is rejected, an audit log entry is created, and a detailed error message is returned explaining which check failed (unknown tool, schema validation, authority denial, etc.).

### How do I add support for a new tool?

1. Generate a candidate schema: `zigshell pack generate <binary>`
2. Review and edit the generated schema in `packs/candidate/<binary>.json`
3. Copy it to `packs/activated/` to enable it
4. Update `.zigshell/project.yaml` to allow the tool if needed

## Contributing

Contributions are welcome! Please ensure your changes:

- Maintain all architectural invariants
- Include tests
- Follow the existing code style
- Don't introduce string-based execution
- Don't bypass authority checks

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

Developed by dmaynor.

## Further Reading

- [ARCHITECTURE.md](ARCHITECTURE.md) - Detailed architecture documentation
- [PLAN.md](PLAN.md) - Development roadmap and codegen prompts
