# AI-Agent Workflow for Gaming Performance Suite

This document defines a maintainable multi-agent workflow for the Gaming Performance Suite project, optimized for Claude Code with support for role-based specialization.

## Environment Detection

This project is designed for **Claude Code** (primary environment). The workflow uses Claude Code's subagent system with markdown-based agent definitions in `.claude/agents/`.

### Supported Environments
- **Claude Code** (Primary) - Native subagent support via `.claude/agents/*.md`
- **OpenAI Codex** - May require adaptation (different agent format)
- **OpenCode** - May require adaptation (different agent format)

The current environment uses Claude Code with subagents enabled.

## Agent Roles

| Agent | Purpose | When to Use |
|-------|---------|-------------|
| `windows-systems-engineer` | PowerShell, Win32 APIs, registry, system optimizations, reversibility | System-level changes, module development, recovery journal |
| `graphics-optimization` | Display scaling, GPU detection, resolution management | Display scaling issues, GPU detection, low-spec optimization |
| `network-diagnostics` | Network diagnostics, latency, packet loss, opt-in tuning | Network issues, diagnostics, tuning with rollback |
| `audio-processing` | WASAPI, DSP pipelines, mic enhancement, virtual audio | Audio/mic enhancement features |
| `performance-profiling` | Bottleneck analysis, overhead measurement, leak detection | Performance validation, regression testing |
| `packaging-deployment` | Build system, installer, shortcuts, uninstall | Packaging, deployment, build issues |
| `qa-testing` | Validation, integration testing, acceptance criteria | Testing, validation, regression checks |
| `security-review` | Anti-cheat compatibility, safety, privacy | Security review, new risky features |
| `code-cleanup` | Dead code removal, style fixes, technical debt | Refactoring, cleanup (after verification) |
| `task-recovery` | Resume interrupted work, preserve changes | Context loss, resuming tasks |
| `documentation` | PRDs, READMEs, guides, API docs | Documentation updates |

## Workflow Guidelines

### General Principles
1. **Preserve user changes** - Always check `git diff` before making changes
2. **Safety first** - All system changes must be reversible and journaled
3. **Verify before removing** - Code cleanup only after confirming unused
4. **Fix errors** - Don't leave broken code
5. **Report honestly** - Document unfinished work
6. **Avoid unnecessary activity** - Use minimal agents needed
7. **No external dependencies** - Use only built-in tools

### Task Routing
- **System-level changes** → `windows-systems-engineer`
- **Performance issues** → `performance-profiling` + `windows-systems-engineer`
- **New features** → Plan with appropriate specialists, implement with domain experts
- **Bugs** → `qa-testing` to reproduce, domain expert to fix
- **Security concerns** → `security-review`
- **Packaging** → `packaging-deployment`

### Safety Boundaries (Global)
- Never inject into games or protected processes (Vanguard, BattlEye, EAC)
- Never create persistent services/tasks/startup entries without approval
- All system changes must be session-scoped and reversible
- Read-only diagnostics by default
- Opt-in for any risky operations
- No telemetry or external data collection
- Preserve anti-cheat compatibility

## Usage in Claude Code

### Using Subagents
```bash
# In Claude Code, use the Task tool or let Claude delegate
# Subagents are automatically available from .claude/agents/
```

### Manual Invocation
Reference agents in your requests: "Use the windows-systems-engineer to fix this PowerShell module issue"

## Verification

Check installed capabilities:
```bash
# List agents
ls .claude/agents/

# Check Claude Code version
claude --version
```

## Setup Instructions

1. Agent definitions are in `.claude/agents/*.md` (version controlled)
2. No additional setup required in Claude Code
3. Agents follow the same safety principles as the project
4. All changes go through normal git workflow
