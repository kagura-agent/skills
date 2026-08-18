---
name: "flowforge"
description: "Correct FlowForge 1.1.2 start/resume and multi-instance CLI usage."
---

# FlowForge Workflow Runner

Execute multi-step workflows defined in YAML files using the FlowForge state machine engine.

## Prerequisites

Check the installed CLI contract before use:

```bash
flowforge --version
flowforge start --help
flowforge status --help
flowforge next --help
```

If the command fails or is not found, run the setup flow in [setup.md](setup.md) before proceeding.

## My Workflows

| Intent | Workflow |
|--------|----------|
| 打工 / contribute / work on issues / PR | `workloop` |
| 学习 / study / research | `study` |
| 反思 / reflect | `reflect` |
| 代码审查 / review code | `review` |
| 审计 / audit | `daily-audit` |
| 工具回顾 / tool review | `tool-review` |
| 进化 / evolve / 执行审计提案 | `evolve` |

## Authoritative Lifecycle

### 1. Inspect active instances first

```bash
flowforge active
```

- If the target workflow already has an active instance, **do not start or run it again**.
- Resume it with `status -w <workflow>` and then `next -w <workflow>`.
- If it is genuinely stale, inspect its current node before using the workflow's explicit stale-recovery procedure.

### 2. Start only when no target instance exists

```bash
flowforge start <workflow-or-yaml-path>
```

`start` creates a new instance. It must never be followed by `flowforge run` for the same task.

### 3. Get the current action

```bash
flowforge status -w <workflow>
```

Read the task and branches. The target workflow name is the YAML `name` field, which may differ from its filename.

### 4. Execute by action type

**`type: 'spawn'`** → Node has `executor: subagent`. **MUST spawn a sub-agent:**

```
sessions_spawn(
  task: action.task,
  mode: "run",
  label: "flowforge-<workflow>-<node>"
)
```

Wait for the sub-agent to complete. Collect its output.

⚠️ **NEVER execute spawn tasks yourself in the main session.**

**`type: 'prompt'`** → Node needs human/agent judgment. Execute the task directly in the main session.

**`type: 'complete'`** → Workflow finished. Report results.

### 4b. Goal-drift check (spawn nodes only)

After a sub-agent returns, verify its output addresses the stated task:

```bash
bash ~/.openclaw/workspace/tools/goal-drift-check.sh \
  --task "<node task description>" \
  --result "<subagent output summary>"
```

If `⚠️ DRIFT DETECTED`, investigate before advancing.

### 5. Advance the same instance explicitly

```bash
flowforge next -w <workflow> --branch <N> --result "<concise result summary>"
```

- Use the selected branch number whenever branches are shown.
- Use `-w <workflow>` on **every** `status`, `next`, and `advance` call when more than one instance can exist.
- `flowforge advance -w <workflow> --result "..."` is supported as a compatibility path, but `next -w` is preferred.
- Advance immediately after a node is completed, before logging or unrelated work.

### 6. `run` is not a resume command

In FlowForge 1.1.2, `flowforge run <workflow>` starts a workflow and does **not** accept `-w`. Do not use either of these patterns:

```bash
flowforge start <workflow> && flowforge run <workflow>
flowforge run -w <workflow>
```

## Rules

- **spawn = sessions_spawn.** Not exec, not Claude Code CLI, not doing it yourself.
- **Never skip nodes.** Execute every node's task before advancing.
- **Run to completion.** Do not reply to the user mid-workflow. Execute all nodes, then report.
- **State persists.** Workflows survive session restarts. Resume explicitly; do not create duplicates.
- **Post-run:** Record results in `memory/YYYY-MM-DD.md`.

## Manual recovery

```bash
flowforge active
flowforge status -w <workflow>
# execute only the displayed node task
flowforge next -w <workflow> --branch <N> --result "..."
```

## Creating New Workflows

See [references/yaml-format.md](references/yaml-format.md) for YAML spec.

```yaml
name: my-workflow
start: first-node
nodes:
  first-node:
    task: What to do
    executor: subagent
    next: second-node
  second-node:
    task: Make a decision
    branches:
      - condition: success
        next: done
      - condition: retry
        next: first-node
  done:
    task: Report results
    terminal: true
```
