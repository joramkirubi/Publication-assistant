<div align="center">

![Publication Assistant](assets/hero-image.svg)

# Publication Assistant for AI Projects

**A LangGraph-orchestrated multi-agent system that reviews a public GitHub repository and tells you exactly what to fix before you publish it.**

![License](https://img.shields.io/badge/license-MIT-green)
![Python](https://img.shields.io/badge/python-3.10%2B-blue)
![Orchestration](https://img.shields.io/badge/orchestration-LangGraph-orange)
![LLM](https://img.shields.io/badge/LLM-Groq-9146FF)
![Tests](https://img.shields.io/badge/tests-15%20passing-brightgreen)

Built as a capstone project for Ready Tensor's Mastering AI Agents certification.

</div>

---

## Table of Contents

- [Overview](#overview)
- [Target Audience](#target-audience)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Testing](#testing)
- [Design Decisions & Limitations](#design-decisions--limitations)
- [License](#license)
- [Contributing](#contributing)

## Overview

You give it a GitHub repo URL. It gives back a report suggesting a better
title and summary, relevant tags, and exactly which standard documentation
sections (README structure, license, installation, etc.) are missing —
grounded in Ready Tensor's own [Open Source Repository Guide](https://app.readytensor.ai)
Essential/Professional criteria, not just a generic opinion.

Four agents collaborate through a shared state object, coordinated by a
LangGraph graph:

| Agent | Role | Tools used |
|---|---|---|
| **Repo Analyzer** | Fetches README, file structure, and repo metadata | `github_repo_reader` |
| **Metadata Recommender** | Suggests tags/keywords for the publication listing | `keyword_extractor` |
| **Content Improver** | Drafts a better title/summary, checks how similar projects are positioned | `web_search` |
| **Reviewer / Critic** | Checks README structure against Ready Tensor's documentation tiers, synthesizes the final report | `readme_structure_checker` |

`Metadata Recommender` and `Content Improver` run as parallel branches — neither
depends on the other's output, so running them concurrently cuts latency
without changing the result. `Reviewer / Critic` waits on both before
compiling the final report.

## Target Audience

AI/ML practitioners preparing a project (GitHub repo) for public sharing —
on Ready Tensor, GitHub, or elsewhere — who want an objective first pass
before investing time in polishing it themselves.

## Architecture

![Architecture diagram](assets/architecture-diagram.svg)

## Prerequisites

- Python 3.10+
- A [Groq API key](https://console.groq.com/keys) (required, free tier available — the agents use a Groq-hosted Llama model for reasoning)
- A [Tavily API key](https://tavily.com/) (optional — enables the web search tool; the pipeline runs without it, just with less positioning context)
- A GitHub personal access token (optional — raises the GitHub API rate limit from 60/hr to 5000/hr)

## Installation

```bash
git clone https://github.com/joramkirubi/Publication-assistant.git
cd publication-assistant
python -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt
cp .env.example .env
# then edit .env and add your GROQ_API_KEY (and optionally TAVILY_API_KEY, GITHUB_TOKEN)
```

## Usage

```bash
python main.py --repo https://github.com/joramkirubi/medical-rag-assistant
```

Every run automatically saves a timestamped markdown report under
`reports/<owner>_<repo>_<timestamp>.md`, in addition to printing it to the
console. Two optional flags change that behavior:

```bash
# Save to a specific path instead of the auto-generated one
python main.py --repo https://github.com/owner/repo --output report.md

# Skip saving entirely, just print to the console
python main.py --repo https://github.com/owner/repo --no-save
```

<details>
<summary><b>Sample output (click to expand)</b> — real, unedited run against an independent repo</summary>

```
Analyzing https://github.com/joramkirubi/medical-rag-assistant ...

## Summary of Findings
The provided README for MedAssist, a medical AI assistant, covers essential
sections such as project title, installation, and license. However, it
lacks critical sections like overview/description, usage, configuration,
testing, and contributing.

## Suggested Title & Summary
MedAssist — Medical AI Assistant: uses Retrieval-Augmented Generation (RAG)
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

✅ Report saved to reports/joramkirubi_medical-rag-assistant_20260702-143012.md
```

</details>

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

## Testing

The tools and agent logic are covered by unit tests. Agent tests mock the
GitHub API and LLM calls so they run offline, without needing real API keys:

```bash
pytest tests/ -v
```

## Design Decisions & Limitations

<details>
<summary><b>Why 4 agents, not fewer?</b></summary>
<br>

Repo analysis, metadata suggestion, content drafting, and review are
genuinely different tasks with different failure modes — separating them
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
<summary><b>Evaluation — deliberately scoped out</b></summary>
<br>

Formal evaluation metrics (task success rate across a benchmark set of
repos, structure-check precision/recall against hand-labeled examples) were
considered as an optional enhancement per the capstone requirements, but
were scoped out of this submission in favor of keeping the four core agents
solid and well-tested. Noted here as a deliberate scope decision, not an
oversight.
</details>

<details>
<summary><b>Known limitations</b></summary>
<br>

- Only public GitHub repos are supported (no GitLab/Bitbucket, no private repos without a token with access).
- The `readme_structure_checker` is regex/heading based — a README that documents installation steps in prose without a heading may be flagged as missing that section.
- `Content Improver`'s suggestions are only as good as the web search context available; without `TAVILY_API_KEY` it drafts from the README alone.
- No automated fact-checking agent yet — the Reviewer/Critic asks the LLM to ground claims in the README, but does not independently verify them.
</details>

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Please run `pytest tests/` before submitting.
