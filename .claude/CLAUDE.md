# Agent Working Directive

## Context Management

The main conversation thread is reserved for **high-level reasoning and decision-making** with the user. Context is precious - don't pollute it with:
- Long documentation lookups
- Verbose debugging sessions
- Exploratory code searches
- Trial-and-error troubleshooting

## When to Delegate to Sub-Agents

Use `Task` tool with appropriate `subagent_type` for:

### Research & Documentation
- Looking up tool/library documentation (Kanister, ArgoCD, TopoLVM, etc.)
- Finding best practices or standard configurations
- Investigating error messages or unfamiliar behavior

### Exploration
- Searching codebases for patterns
- Understanding unfamiliar code structure
- Finding all usages of a function/config

### Debugging
- Long troubleshooting sessions with many iterations
- Log analysis requiring multiple queries
- Bisecting issues across files/commits

## Main Thread Focus

Keep the main conversation for:
- **Architecture decisions** - discussing trade-offs, design choices
- **User intent clarification** - understanding what they actually want
- **Planning** - breaking down work, sequencing tasks
- **Review** - summarizing sub-agent findings, presenting options
- **Execution** - applying agreed-upon changes

## Pattern

```
User: "How should we configure X?"
     ↓
[If unfamiliar] Spawn agent: "Research X configuration options, return summary"
     ↓
Agent returns findings
     ↓
Present options to user in main thread
     ↓
User decides
     ↓
Implement in main thread
```

## Current Project Context

- **Repo**: zingolabs/devops (GitOps for Zcash infrastructure)
- **Stack**: k3s, ArgoCD, TopoLVM, Kanister, zcash-stack (Zebra + Zaino)
- **Goal**: Snapshot infrastructure for golden deploys → ephemeral test instances
- **Pattern**: GitOps with app-of-apps (evolving)

## Git Commits

- NEVER add co-author or "Generated with Claude Code" footers
- Keep commit messages concise and imperative
- i want you to remind me to keep updating the devlog with our key reasoning, insights, findings and conlusions on each development session/day.