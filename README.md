# Autonomous Dev Agent — Salesforce engine

An AI developer that lives in a Salesforce org. Every day at **08:00 UTC** it plans, writes, tests,
reviews and merges one pull request into [`pratiks2003/agent-forge`](https://github.com/pratiks2003/agent-forge).
Its live dashboard is an Experience Cloud LWR site:
**https://orgfarm-bd59095f65-dev-ed.develop.my.site.com/agent**

```
DailyAgentOrchestrator (Schedulable, 08:00 UTC)
  └─ AgentContextStage   sweep yesterday's PRs · GraphQL repo context · sync / self-generate quests
  └─ AgentCodeGenStage   RAG retrieval · Einstein Models API (Claude Sonnet 4 via Trust Layer) → JSON
  └─ AgentShipStage      branch · 2 commits · PR · AI review · auto-merge · weekly release · profile README
       AgentStageFinalizer marks failures and requeues the quest
GitHub Actions (in agent-forge)
  ci.yml                 tsc --noEmit + vitest on every PR (required check "build-test")
  watchdog-failover.yml  20:00 UTC: no contribution today? run the same pipeline with GitHub Models
```

## What's in here

| Path                                                         | Purpose                                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `objects/Agent_Quest__c`, `objects/Agent_Run_Log__c`         | Quest backlog and per-run telemetry (incl. contribution snapshot JSON)   |
| `objects/Agent_Config__mdt` + `customMetadata/`              | Owner, repo, profile repo, dashboard URL, model, release cadence         |
| `classes/GitHubGraphQLService`                               | Repo context, RAG file fetch, contribution calendar, auto-merge mutation |
| `classes/AutonomousQuestGenerator`                           | Invents a quest when fewer than 3 are open; opens the GitHub issue       |
| `classes/AgentRAGCodeEngine`                                 | Context selection, code-generation prompt, path safety validation        |
| `classes/AgentLLMClient`                                     | `aiplatform.ModelsAPI` wrapper with tolerant JSON extraction + retry     |
| `classes/GitHubLifecycleService`                             | Branch, commits, PR, review, merge, sweep, releases, profile README      |
| `classes/AgentCommandCenterController`                       | Guest-safe dashboard data + admin-only actions                           |
| `lwc/agentCommandCenter`                                     | The dark-mode command center UI                                          |
| `namedCredentials/GitHub_API` + `externalCredentials/GitHub` | PAT injected as `Authorization: Bearer`                                  |
| `permissionsets/Agent_Command_Admin`                         | Runs the agent; `Agent_Command_Center_Viewer` is for the site guest      |

## Operating it

```bash
# 1. Store the GitHub PAT in the org (never committed)
export GITHUB_PAT=github_pat_xxx && ./scripts/setup-github-credential.sh

# 2. Manual run / schedule (scheduling user must be on GMT)
sf apex run -o watchitbuild -f scripts/apex/run-now.apex
sf apex run -o watchitbuild -f scripts/apex/go-live.apex

# Tests
sf apex run test -o watchitbuild -n AgentPipelineTest -n AgentCommandCenterControllerTest -c -w 15
npm run test:unit
```

**Token:** the GitHub PAT is set to no expiry. If it is ever rotated, update both the `GitHub` External Credential (`./scripts/setup-github-credential.sh`) and the `AGENT_PAT` secret of `agent-forge`.

