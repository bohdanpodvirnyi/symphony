---
tracker:
  kind: github
  repository: "your-org/your-repo"
  project_owner: "your-org"
  project_number: 12
  api_key: $GITHUB_TOKEN
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 1
  max_turns: 8
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on GitHub issue `{{ issue.identifier }}`.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:
- Treat GitHub Projects v2 **Status** as source of truth for workflow state.
- Keep one persistent workpad comment on the issue.
- Before human review: lint + build + manual runtime checks required by repo workflow.
- Final response: completed actions + blockers only.
