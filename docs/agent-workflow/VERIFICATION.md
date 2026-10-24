# Workflow Verification Checklist

Use this checklist to verify the agent workflow is properly configured and functional.

## Configuration Files
- [x] `.claude/agents/` directory exists with 11 agent files
- [x] All agents have proper frontmatter (name, description, tools, model)
- [x] `.claude/commands/` has custom commands
- [x] `.claude/skills/` has coordination skill
- [x] Documentation in `docs/agent-workflow/`
- [x] Settings in `.claude/settings.local.json` reviewed

## Agent Roles Coverage
- [x] Windows Systems Engineer - PowerShell, Win32, system
- [x] Graphics Optimization - Display, GPU, scaling
- [x] Network Diagnostics - Network, latency, tuning
- [x] Audio Processing - WASAPI, DSP, mic
- [x] Performance Profiling - Overhead, leaks, metrics
- [x] Packaging & Deployment - Build, installer, uninstall
- [x] QA & Testing - Validation, regression, acceptance
- [x] Security Review - Anti-cheat, safety, privacy
- [x] Code Cleanup - Dead code, style (verified removal)
- [x] Task Recovery - Resume work, preserve changes
- [x] Documentation - PRDs, READMEs, guides

## Safety Boundaries
- [x] Anti-cheat compatibility documented
- [x] Reversibility emphasized
- [x] No injection/modification of games
- [x] Opt-in for risky operations
- [x] Journal/rollback patterns referenced
- [x] Preserve user changes
- [x] Fix errors, report unfinished work
- [x] Remove code only after verification

## Environment Compatibility
- [x] Claude Code format used (native)
- [x] Documentation for Codex/OpenCode adaptation
- [x] Setup instructions provided
- [x] Capabilities verification documented

## Testing
- [ ] Agents load in Claude Code
- [ ] Can delegate to specific agents
- [ ] Safety boundaries enforced
- [ ] Tools accessible to agents
- [ ] Workflow coordination works

## Notes
- Current environment is Claude Code (detected from paths and structure)
- All configurations are version-controlled
- No unnecessary external dependencies added
- Follows project conventions and safety requirements
