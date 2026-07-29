# Architecture

## Purpose

Publication Assistant reviews a public GitHub repository and produces a
markdown report recommending: a better title/summary, publication tags,
and which standard documentation sections are missing -- grounded in
Ready Tensor's Open Source Repository Guide (Essential/Professional
tiers), not just an LLM's unstructured opinion.

## System overview

```
                                +-------------------+
   repo_url ------------------>|   Repo Analyzer    |
   user_description             | (GitHub REST API)  |
                                +----------+----------+
                                           |
                        +------------------+------------------+
                        |                                     |
                        v                                     v
             +----------------------+              +----------------------+
             | Metadata Recommender |              |  Content Improver    |
             | (keyword extraction  |              |  (web search +       |
             |  + LLM tag refine)   |              |   LLM drafting)      |
             +----------+-----------+              +----------+-----------+
                        |                                     |
                        +------------------+------------------+
                                           |
                                [ HUMAN REVIEW CHECKPOINT ]
                                (interrupt_before, resumable
                                 via LangGraph checkpointer)
                                           |
                                           v
                                +----------------------+
                                |   Reviewer / Critic   |
                                | (structure check tool |
                                |  + LLM synthesis)     |
                                +----------+-----------+
                                           |
                                           v
                                    final_report (md)
```

`Metadata Recommender` and `Content Improver` run as parallel branches of
a `StateGraph` fan-out/fan-in (see `src/graph.py`) since neither depends
on the other's output. `Reviewer / Critic` waits on both, then the graph
pauses (`interrupt_before=["reviewer_critic"]`) so a human can review or
edit the suggestions before the final report is generated.

## Key components

| Layer | Module(s) | Responsibility |
|---|---|---|
| Orchestration | `src/graph.py` | Builds and runs the LangGraph `StateGraph`; owns the human-in-the-loop pause/resume. |
| Shared state | `src/state.py` | Single `TypedDict` all agents read/write; `errors` uses an `operator.add` reducer for concurrent writes. |
| Agents | `src/agents/*.py` | Four single-responsibility agents (see table below). |
| Tools | `src/tools/*.py` | Deterministic, non-LLM functions agents call: GitHub API reader, keyword extractor, README structure checker, web search. |
| Guardrails | `src/guardrails.py` | Input validation/sanitization (repo URL, description) and output filtering (secret redaction). |
| Resilience | `src/resilience.py` | Retry-with-backoff and hard-timeout decorators, applied to every outbound network/LLM call. |
| Health | `src/health.py` | Config + connectivity checks, exposed via CLI and UI. |
| LLM client | `src/llm.py` | Single place all agents get a configured `ChatGroq` client + resilient invoke wrapper. |
| Entry points | `main.py` (CLI), `app.py` (Streamlit UI) | Thin presentation layers over the same `src/graph.py` pipeline. |

| Agent | Role | Tools used |
|---|---|---|
| Repo Analyzer | Fetches README, file structure, repo metadata. No LLM reasoning -- deliberately mechanical so failures are predictable. | `github_repo_reader` |
| Metadata Recommender | Suggests 5-8 publication tags. | `keyword_extractor` |
| Content Improver | Drafts title/summary/positioning, grounded strictly in the README. | `web_search` |
| Reviewer / Critic | Checks README structure against Ready Tensor's tiers, synthesizes the final report, incorporates human feedback. | `readme_structure_checker` |

## Data flow / interface

See [API.md](API.md) for the full state schema (the "interface" between
agents, and between the pipeline and its two front ends).

## Design decisions

- **Why 4 agents, not fewer?** Repo analysis, metadata suggestion,
  content drafting, and review are genuinely different tasks with
  different failure modes -- separating them keeps prompts focused and
  isolates failures to `state["errors"]`.
- **Why LangGraph specifically?** The pipeline has a real fan-out/fan-in
  shape, which LangGraph's graph model expresses directly rather than
  forcing a linear chain.
- **Why a thread-based timeout instead of `signal.alarm`?** This project
  targets Windows (no `SIGALRM` support), so `src/resilience.py` uses a
  `ThreadPoolExecutor`-based timeout instead.
- **Why regex-based guardrails instead of an LLM-based safety agent?**
  Input validation and secret redaction need to be deterministic and run
  before/after LLM calls without themselves depending on an LLM call that
  could fail or be slow.

## Known limitations

- Only public GitHub repos are supported (no GitLab/Bitbucket, no private
  repos without a token with access).
- `readme_structure_checker` is regex/heading based -- prose without a
  heading may be flagged as a missing section.
- `Content Improver`'s suggestions are only as good as available web
  search context; without `TAVILY_API_KEY` it drafts from the README
  alone.
- No automated fact-checking agent -- Reviewer/Critic is prompted to
  ground claims in the README but doesn't independently verify them.
- The pipeline is a fixed DAG, not a looping agent, so "iteration/loop
  caps" (a resilience requirement aimed at agentic loops) don't apply in
  the same way here; the equivalent risk -- a single node hanging -- is
  covered by `with_timeout` instead.