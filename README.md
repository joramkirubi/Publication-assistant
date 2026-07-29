<div align="center">

# Publication Assistant for AI Projects

**A LangGraph-orchestrated multi-agent system that reviews a public GitHub repository and tells you exactly what to fix before you publish it.**

![License](https://img.shields.io/badge/license-MIT-green)
![Python](https://img.shields.io/badge/python-3.10%2B-blue)
![Orchestration](https://img.shields.io/badge/orchestration-LangGraph-orange)
![LLM](https://img.shields.io/badge/LLM-Groq-9146FF)
![UI](https://img.shields.io/badge/UI-Streamlit-FF4B4B)
![Tests](https://img.shields.io/badge/tests-78%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/coverage-97%25-brightgreen)

Built as a capstone project for Ready Tensor's Mastering AI Agents
certification, then hardened into a production-grade system for the
Agentic AI In Production certification.

</div>

---

## Table of Contents

- [Overview](#overview)
- [Target Audience](#target-audience)
- [Architecture](#architecture)
- [Production-Grade Enhancements](#production-grade-enhancements)
- [Human-in-the-Loop Review](#human-in-the-loop-review)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Web UI](#web-ui)
- [Configuration](#configuration)
- [Guardrails & Security](#guardrails--security)
- [Resilience & Monitoring](#resilience--monitoring)
- [Testing](#testing)
- [Documentation](#documentation)
- [Design Decisions & Limitations](#design-decisions--limitations)
- [License](#license)
- [Contributing](#contributing)

## Overview

You give it a GitHub repo URL. It gives back a report suggesting a better
title and summary, relevant tags, and exactly which standard documentation
sections (README structure, license, installation, etc.) are missing --
grounded in Ready Tensor's own Open Source Repository Guide
Essential/Professional criteria, not just a generic opinion.

Four agents collaborate through a shared state object, coordinated by a
LangGraph graph:

| Agent | Role | Tools used |
|---|---|---|
| **Repo Analyzer** | Fetches README, file structure, and repo metadata | `github_repo_reader` |
| **Metadata Recommender** | Suggests tags/keywords for the publication listing | `keyword_extractor` |
| **Content Improver** | Drafts a better title/summary, checks how similar projects are positioned | `web_search` |
| **Reviewer / Critic** | Checks README structure against Ready Tensor's documentation tiers, synthesizes the final report | `readme_structure_checker` |

`Metadata Recommender` and `Content Improver` run as parallel branches --
neither depends on the other's output, so running them concurrently cuts
latency without changing the result. `Reviewer / Critic` waits on both
before compiling the final report.

## Target Audience

AI/ML practitioners preparing a project (GitHub repo) for public sharing --
on Ready Tensor, GitHub, or elsewhere - who want an objective first pass
before investing time in polishing it themselves.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full system
diagram, component table, and design rationale.

## Production-Grade Enhancements

This system started as a Mastering AI Agents certification prototype and
was hardened for the Agentic AI In Production certification. What changed:

| Requirement | What was added |
|---|---|
| **Testing** | 78 tests, 97% statement coverage on `src/` (well above the 70% bar), covering every agent, tool, and the new guardrails/resilience/health modules. All mock external calls and run offline. |
| **Guardrails & security** | `src/guardrails.py`: strict repo-URL validation (rejects non-GitHub hosts, path traversal, lookalike domains), input sanitization, and output secret-redaction on the final report. See [Guardrails & Security](#guardrails--security). |
| **User interface** | `app.py`: a Streamlit web UI with the same input -> human-review -> report flow as the CLI, plus a sidebar health-check and a download button. See [Web UI](#web-ui). |
| **Resilience & monitoring** | `src/resilience.py`: retry-with-exponential-backoff and hard wall-clock timeouts wrap every outbound call (GitHub API, Tavily, Groq). `src/health.py`: a config/connectivity health check exposed via `--health-check` and the UI sidebar. See [Resilience & Monitoring](#resilience--monitoring). |
| **Documentation** | This README plus [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/API.md](docs/API.md), [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). |

Every existing agent's own try/except-and-degrade behavior was left
intact; the new guardrails/resilience layers sit around that logic rather
than replacing it.

## Human-in-the-Loop Review

The graph genuinely pauses right before the Reviewer/Critic agent runs --
using LangGraph's `interrupt_before` mechanism backed by a checkpointer --
so you can inspect the suggested title, summary, and tags, edit any of
them, and leave free-text feedback before the final report is generated.
The edited values and feedback are injected back into shared state and are
what Reviewer/Critic actually reads when it resumes; this is verified by a
dedicated test (`tests/test_human_in_the_loop.py`) that inspects the exact
text sent to the LLM after an edit.

**Two issues surfaced only through real, interactive execution - not the
mocked test suite alone:**

1. Because Metadata Recommender and Content Improver write to state in the
   same parallel step, applying a human's edit via `update_state()` raised
   `InvalidUpdateError: Ambiguous update, specify as_node` - LangGraph
   couldn't infer which of the two simultaneous writers the edit belonged
   to. Fixed by explicitly passing `as_node="content_improver"`.
2. The interactive approve/edit prompt initially treated any unrecognized
   input - not just `n` or `e` - as silent approval. Fixed by validating
   input and re-prompting until a real Y/n/e answer is given, backed by a
   dedicated regression test (`tests/test_cli_review_checkpoint.py`).

Both trace back to the same architectural choice: Metadata Recommender and
Content Improver running in parallel for latency. That's a deliberate
tradeoff, and these two bugs are a concrete part of its cost.

Pass `--auto-approve` (CLI) to skip the interactive prompt for
scripted/CI use.

## Prerequisites

- Python 3.10+
- A [Groq API key](https://console.groq.com/keys) (required, free tier available - the agents use a Groq-hosted Llama model for reasoning)
- A [Tavily API key](https://tavily.com/) (optional - enables the web search tool; the pipeline runs without it, just with less positioning context)
- A GitHub personal access token (optional - raises the GitHub API rate limit from 60/hr to 5000/hr)

## Installation

```bash
git clone https://github.com/joramkirubi/Publication-assistant.git
cd Publication-assistant
python -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt
cp .env.example .env
# then edit .env and add your GROQ_API_KEY (and optionally TAVILY_API_KEY, GITHUB_TOKEN)
```

Windows/PowerShell equivalents and a full deployment walkthrough are in
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Usage

```bash
python main.py --repo https://github.com/joramkirubi/medical-rag-assistant
```

By default, the graph pauses right before the final report is generated so
you can review, edit, or leave feedback on the suggested title/tags/summary
 - see [Human-in-the-Loop Review](#human-in-the-loop-review) above. Pass
`--auto-approve` to skip that prompt for scripted/non-interactive use:

```bash
python main.py --repo https://github.com/owner/repo --auto-approve
```

Every run automatically saves a timestamped markdown report under
`reports/<owner>_<repo>_<timestamp>.md`, in addition to printing it to the
console. A few more flags:

```bash
# Save to a specific path instead of the auto-generated one
python main.py --repo https://github.com/owner/repo --output report.md

# Skip saving entirely, just print to the console
python main.py --repo https://github.com/owner/repo --no-save

# Check configuration and connectivity without running the pipeline
python main.py --health-check
```

<details>
<summary><b>Sample output (click to expand)</b> - real, unedited run against an independent repo</summary>

```
Analyzing https://github.com/joramkirubi/medical-rag-assistant ...

## Summary of Findings
The provided README for MedAssist, a medical AI assistant, covers essential
sections such as project title, installation, and license. However, it
lacks critical sections like overview/description, usage, configuration,
testing, and contributing.

## Suggested Title & Summary
MedAssist - Medical AI Assistant: uses Retrieval-Augmented Generation (RAG)
and ReAct reasoning strategy for medical question answering.

## Suggested Tags
Retrieval-Augmented-Generation, RAG, LangChain, HuggingFace, Groq,
ChromaDB, ReAct, MedicalQuestionAnswering, Streamlit

## Missing Sections
- Overview / Description
- Usage
- Configuration
- Testing
- Contributing

## Overall Recommendation
Add the missing essential and professional sections to improve usability,
maintainability, and community engagement.

[OK] Report saved to reports/joramkirubi_medical-rag-assistant_20260702-143012.md
```

</details>

## Web UI

For a non-technical or interactive workflow, run the Streamlit app instead
of the CLI:

```bash
streamlit run app.py
```

This opens a local web UI (`http://localhost:8501`) with three screens:

1. **Input** - paste a repo URL and optional description.
2. **Human review** - edit the suggested title/summary/tags and leave
   feedback, mirroring the CLI's interactive checkpoint.
3. **Report** - the rendered final report plus a "Download report (.md)"
   button.

The sidebar has a **Run health check** button (see
[Resilience & Monitoring](#resilience--monitoring)) and a **Start over**
button to reset the session. The UI is a thin wrapper over
`src/graph.py` - it contains no pipeline logic of its own, so everything
documented above about the pipeline's behavior applies here unchanged.

## Configuration

All configuration is via environment variables, loaded from `.env`
(see `.env.example`):

| Variable | Required | Purpose |
|---|---|---|
| `GROQ_API_KEY` | Yes | LLM calls for all four agents |
| `TAVILY_API_KEY` | No | Enables the `web_search` tool |
| `GITHUB_TOKEN` | No | Raises GitHub API rate limits |
| `MODEL_NAME` | No | Defaults to `llama-3.3-70b-versatile` |
| `MODEL_TEMPERATURE` | No | Defaults to `0.3` |

## Guardrails & Security

`src/guardrails.py` sits at both edges of the system:

- **Input validation** - `validate_repo_url` accepts only
  `https://github.com/<owner>/<repo>`-shaped URLs: no other hosts
  (blocks SSRF-style redirection to internal hosts), no `http://`, no
  extra path segments, no control characters, capped length. Both the CLI
  and the UI funnel through this single validator via `start_pipeline`.
- **Input sanitization** - `sanitize_user_description` strips control
  characters, collapses whitespace, and caps the optional free-text
  description at 500 characters before it ever reaches an LLM prompt.
- **Output filtering** - `filter_output` runs a regex-based redaction pass
  over the final report for anything that looks like a leaked API key
  (Groq, GitHub, Tavily, AWS, generic `sk-` style keys), as a last-resort
  net against a README or web-search snippet echoing a real credential
  back through the LLM.
- **Error handling** - every agent already wrapped its own logic in
  try/except with graceful degradation (recorded in `state["errors"]`,
  surfaced in the final report and CLI/UI output); `main.py` and `app.py`
  additionally catch `GuardrailViolation` and any unexpected pipeline
  exception at the top level so a bad input or surprise failure prints a
  clear message and exits cleanly instead of an unhandled traceback.

## Resilience & Monitoring

`src/resilience.py` provides two decorators applied to every outbound
network/LLM call (GitHub API reads, `invoke_llm` for all three
LLM-calling agents):

- **`with_retry`** - retries transient failures (connection errors,
  timeouts, 5xx/429 responses) up to a bounded number of attempts with
  exponential backoff, then re-raises so the existing per-agent
  degradation logic handles a genuinely persistent failure.
- **`with_timeout`** - runs the call in a worker thread with a hard
  wall-clock timeout, raising `ResilienceTimeoutError` instead of letting
  a hung call stall the whole pipeline. Thread-based (not
  `signal.alarm`-based) so it works on Windows, this project's primary
  target environment.

`src/health.py` provides a fast, side-effect-free health check (config
presence + one lightweight connectivity probe per external service) via:

```bash
python main.py --health-check
```

or the **Run health check** button in the Streamlit sidebar. Useful as a
deployment smoke test or a periodic scheduled check.

Logging: both entry points configure Python's standard `logging` at
`INFO` level; every agent logs a full traceback (`logger.exception`) on
failure before degrading gracefully, so application logs are the first
place to look for a root cause.

Note on iteration/loop caps: this pipeline is a fixed DAG, not a looping
agent, so a loop-limit guardrail (aimed at agentic loops that could run
away) doesn't have a direct equivalent here - the analogous risk (a
single node hanging) is covered by `with_timeout` instead. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#known-limitations) for the
full reasoning.

## Testing

The tools, agents, guardrails, resilience helpers, and health checks are
all covered by unit tests. Everything mocks external calls (GitHub API,
LLM calls, Tavily) so the suite runs offline, without needing real API
keys:

```bash
pytest tests/ -v
pytest tests/ --cov=src --cov-report=term-missing   # 97% coverage on src/
```

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - system diagram, component
  table, design decisions, known limitations.
- [docs/API.md](docs/API.md) - state schema and CLI/UI interface
  specification.
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) - install, configure, run
  (CLI + UI), test, and optionally containerize.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) - common issues and
  FAQ.

## Design Decisions & Limitations

<details>
<summary><b>Why 4 agents, not fewer?</b></summary>
<br>

Repo analysis, metadata suggestion, content drafting, and review are
genuinely different tasks with different failure modes - separating them
keeps each agent's prompt focused and makes failures easier to isolate (see
`errors` in the shared state).
</details>

<details>
<summary><b>Why LangGraph specifically?</b></summary>
<br>

The pipeline has a real fan-out/fan-in shape (two independent branches
converging on the reviewer), which LangGraph's graph model expresses
directly, rather than forcing a linear chain.
</details>

<details>
<summary><b>A bug we hit and fixed</b></summary>
<br>

Running two agents in parallel that both write to the same shared-state
field (`errors`) caused a LangGraph `InvalidUpdateError`, since concurrent
writes to one key need an explicit merge rule. Fixed by annotating that
field with a reducer (`Annotated[list[str], operator.add]` in `src/state.py`)
so concurrent writes concatenate instead of conflicting. A regression test
in `tests/test_agents_with_mocks.py` reproduces this exact scenario.
</details>

<details>
<summary><b>Evaluation - deliberately scoped out</b></summary>
<br>

Formal evaluation metrics (task success rate across a benchmark set of
repos, structure-check precision/recall against hand-labeled examples) were
considered as an optional enhancement, but were scoped out of this
submission in favor of keeping the four core agents solid and
well-tested, and prioritizing the production-hardening requirements
(guardrails, resilience, UI, docs) instead. Noted here as a deliberate
scope decision, not an oversight.
</details>

<details>
<summary><b>Known limitations</b></summary>
<br>

- Only public GitHub repos are supported (no GitLab/Bitbucket, no private
  repos without a token with access).
- The `readme_structure_checker` is regex/heading based - a README that
  documents installation steps in prose without a heading may be flagged
  as missing that section.
- `Content Improver`'s suggestions are only as good as the web search
  context available; without `TAVILY_API_KEY` it drafts from the README
  alone.
- No automated fact-checking agent yet - the Reviewer/Critic asks the LLM
  to ground claims in the README, but does not independently verify them.
- This is a fixed-DAG pipeline, not a looping agent, so loop/iteration
  caps aren't directly applicable (see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#known-limitations)).
</details>

## License

MIT - see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Please run `pytest tests/` before submitting.