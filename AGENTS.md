# AGENTS.md - Multi-Agent Setup Guide

Super-Mem enables seamless context sharing and semantic code search between different AI coding agents. This guide covers setup for all supported agents.

## Supported Agents

| Agent | Integration | Doc |
|-------|-------------|-----|
| Claude Code | MCP Server (native) | [CLAUDE.md](CLAUDE.md) |
| Claude Desktop | MCP Server (native) | [README.md](README.md#claude-desktop) |
| Gemini CLI | MCP Server | [GEMINI.md](GEMINI.md) |
| Codex CLI | MCP Server | [CODEX.md](CODEX.md) |
| OpenCode | MCP Server | [OPENCODE.md](OPENCODE.md) |
| Custom Agents | Python API | [README.md](README.md#custom-agents) |

## Features

All agents have access to:

### Memory Tools
- `mem_observe` - Store observations (decisions, issues, discoveries)
- `mem_context` - Get project history and handoff notes
- `mem_search` - Search memory for specific topics
- `mem_handoff` - Pass context to next agent
- `mem_stats` - Get memory statistics
- `mem_set_path` - Change project path

### Code Search Tools (Pommel)
- `code_search` - Semantic code search (local-first priority)
- `code_status` - Check index status
- `code_reindex` - Trigger reindex
- `smart_context` - Unified memory + code context

## Code Search - Local First Priority

**Pass your working directory via the `path` parameter** to search local project first, with automatic fallback to global search.

```
code_search query="signal generator" path="/opt/hcloud"
```

1. **First**: Searches within the path you provide
2. **Fallback**: If no results, searches all indexed code (`/opt/`)
3. **No path**: Omit `path` to search everything globally

Note: `SUPER_MEM_PATH` is for memory storage. Code search uses the `path` parameter you pass.

## Quick Setup

### All Agents: Install Super-Mem

```bash
pip install super-mem-mcp
```

### Claude Code / Claude Desktop (MCP)

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "super-mem": {
      "type": "stdio",
      "command": "super-mem-mcp",
      "env": { "SUPER_MEM_PATH": "/path/to/project" }
    }
  }
}
```

Pre-approve tools in `~/.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__super-mem__mem_observe",
      "mcp__super-mem__mem_context",
      "mcp__super-mem__mem_search",
      "mcp__super-mem__mem_handoff",
      "mcp__super-mem__mem_stats",
      "mcp__super-mem__mem_set_path",
      "mcp__super-mem__code_search",
      "mcp__super-mem__code_status",
      "mcp__super-mem__code_reindex",
      "mcp__super-mem__smart_context"
    ]
  }
}
```

### Gemini CLI (MCP)

Add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "super-mem": {
      "command": "/usr/local/bin/super-mem-mcp",
      "env": { "SUPER_MEM_PATH": "/path/to/project" }
    }
  }
}
```

### Codex CLI (MCP)

```bash
codex mcp add super-mem /usr/local/bin/super-mem-mcp
```

Or edit `~/.codex/config.toml`:

```toml
[mcp.super-mem]
command = "/usr/local/bin/super-mem-mcp"
env = { SUPER_MEM_PATH = "/path/to/project" }
```

### OpenCode (MCP)

Add to `~/.config/opencode/opencode.json`:

```json
{
  "mcp": {
    "super-mem": {
      "type": "local",
      "command": ["/usr/local/bin/super-mem-mcp"],
      "environment": { "SUPER_MEM_PATH": "/path/to/project" },
      "enabled": true
    }
  }
}
```

## Multi-Agent Workflow

### Example: Feature Implementation

```
┌─────────────────────────────────────────────────────────────────┐
│  1. CLAUDE: Analyze & Plan                                      │
│     - Uses code_search to understand codebase                   │
│     - Creates implementation plan                               │
│     - Records decisions via mem_observe                         │
│     - Handoff: "Plan complete. Start with user model."          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. CODEX: Generate Code                                        │
│     - Gets context: sees Claude's plan via mem_context          │
│     - Uses code_search to find similar patterns                 │
│     - Generates user model code                                 │
│     - Records implementation details                            │
│     - Handoff: "Model complete. Need API endpoints."            │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. OPENCODE: Implement API                                     │
│     - Gets context: sees plan + model                           │
│     - Uses smart_context for memory + relevant code             │
│     - Implements REST endpoints                                 │
│     - Records issues found and fixes                            │
│     - Handoff: "API done. Ready for testing."                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. GEMINI: Review & Test                                       │
│     - Gets full context: plan, model, API                       │
│     - Uses code_search to find test patterns                    │
│     - Writes tests                                              │
│     - Records test coverage info                                │
│     - Handoff: "Tests passing. Ready for deploy."               │
└─────────────────────────────────────────────────────────────────┘
```

### Commands at Each Stage (MCP)

All agents use the same MCP tools:

```
# Start of session
Use mem_context to see what previous agents did
Use code_status to check search index is ready

# Find relevant code (pass your working directory)
Use code_search query="authentication" path="/opt/hcloud" to find auth implementations
Use smart_context query="user model" to get memory + code together

# Record decisions
Use mem_observe type="decision" title="Database Choice" content="Using PostgreSQL..."

# End of session
Use mem_handoff summary="Completed X. Next steps: Y"
```

## Observation Types Reference

| Type | When to Use |
|------|-------------|
| `decision` | Architecture choices, tech selections |
| `discovery` | Found important info about codebase |
| `implementation` | Code/feature implementation details |
| `issue` | Bugs, problems, blockers |
| `resolution` | How issues were fixed |
| `context` | General background info |
| `requirement` | User/business requirements |
| `assumption` | Assumptions being made |
| `risk` | Potential problems identified |
| `todo` | Tasks for later |
| `learned` | Lessons learned |
| `handoff` | Notes for next agent |

## Best Practices

1. **Start with context + code search** - Check what previous agents did, find relevant code
2. **Use local-first search** - Let code_search prioritize your current project
3. **Record decisions immediately** - Don't wait until the end
4. **Use specific types** - Helps with searching later
5. **Include file paths** - In mem_observe, list relevant files
6. **End with meaningful handoff** - Summarize and list next steps
7. **Set importance levels** - 1-10, higher for critical decisions

## Troubleshooting

### Memory not persisting
```bash
# Check SUPER_MEM_PATH is set correctly
echo $SUPER_MEM_PATH

# Check .supermem directory exists
ls -la $SUPER_MEM_PATH/.supermem/
```

### Code search not working
```
# Check daemon status
Use code_status

# If daemon not running, it will auto-start on first search
# If index outdated:
Use code_reindex
```

### Can't see other agent's observations
```
# Verify you're using the same SUPER_MEM_PATH
Use mem_stats  # Shows project path and observation count

# Search for specific content
Use mem_search query="keyword"
```

### MCP connection issues
```bash
# Test MCP server directly
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | super-mem-mcp

# Verify it lists all 10 tools
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | super-mem-mcp
```
