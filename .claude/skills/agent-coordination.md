# Agent Coordination Skill

This skill helps coordinate multiple agents for complex tasks while respecting safety boundaries and avoiding unnecessary activity.

## When to Use
- Multi-domain changes requiring different specializations
- Complex debugging across multiple modules
- Major refactoring with safety implications
- Recovery from interrupted work

## Coordination Principles
1. **Minimal agents** - Use only what's needed
2. **Clear boundaries** - Each agent stays in their domain
3. **Safety first** - Security review for risky changes
4. **Preserve changes** - Check git status before starting
5. **Verify everything** - Test after changes
6. **Report honestly** - Document incomplete work

## Workflow Pattern
1. **Assess** - Understand scope, check git status, identify affected modules
2. **Plan** - Determine which agents needed, define clear tasks
3. **Delegate** - Give each agent specific, bounded tasks
4. **Coordinate** - Ensure handoffs are clean, no conflicts
5. **Verify** - Test all changes, check for regressions
6. **Document** - Update docs, report status

## Safety Checklist
- [ ] Git status checked - user changes preserved
- [ ] Security review if system/network changes
- [ ] Reversibility verified
- [ ] No anti-cheat impact
- [ ] Tests pass
- [ ] Documentation updated
