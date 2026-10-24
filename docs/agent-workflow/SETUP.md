# Agent Workflow Setup Instructions

## For Claude Code (Current Environment)

The agent workflow is already configured in this repository:
- Agent definitions: `.claude/agents/*.md` (11 specialized agents)
- Commands: `.claude/commands/`
- Skills: `.claude/skills/`
- Documentation: `docs/agent-workflow/`

No additional setup is required. Claude Code will automatically load agents from `.claude/agents/`.

### Verification
```bash
# Check agents are present
ls -la .claude/agents/

# In Claude Code, agents appear in Task tool
```

## For OpenAI Codex

Codex uses different agent configuration formats. Adaptation needed:
- Convert `.claude/agents/*.md` to Codex agent format
- May need custom instructions or different structure
- Check Codex documentation for current agent/subagent support

## For OpenCode

OpenCode has its own agent system. Adaptation needed:
- Review OpenCode agent configuration format
- Convert markdown agents to OpenCode format
- May need different tool specifications

## Checking Installed Capabilities

In any environment, verify:
1. **Subagent support** - Can you spawn specialized agents?
2. **Custom agents** - Can you load from project files?
3. **Tool access** - Do agents have required tools (Read, Edit, Write, Bash, etc.)?
4. **Project instructions** - Are `.claude/` or equivalent files loaded?

## Testing the Workflow

1. Start Claude Code in this project directory
2. Ask Claude to use a specific agent: "Use the windows-systems-engineer to review Common.psm1"
3. Verify the agent loads with correct role and boundaries
4. Test safety boundaries are respected

## Troubleshooting

- **Agents not appearing**: Ensure files are in `.claude/agents/` with proper frontmatter
- **Wrong model**: Check `model:` field in agent definition
- **Missing tools**: Verify `tools:` list includes needed tools
- **Permissions**: Check `.claude/settings.local.json` for any restrictions
