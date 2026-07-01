# Publication Assistant for AI Projects

A LangGraph-orchestrated multi-agent system that reviews a public GitHub
repository and returns concrete suggestions for making it more discoverable,
clear, and complete before you publish it — built as a capstone project for
Ready Tensor's Mastering AI Agents certification.

## Overview

You give it a GitHub repo URL. It gives back a report suggesting a better
title and summary, relevant tags, and exactly which standard documentation
sections (README structure, license, installation, etc.) are missing —
grounded in Ready Tensor's own [Open Source Repository Guide](https://app.readytensor.ai)
Essential/Professional criteria, not just a generic opinion.

Four agents collaborate through a shared state object, coordinated by a
LangGraph graph:

```
                 ┌─────────────────────┐
   repo_url ───► │   Repo Analyzer      │
                 └──────────┬───────────┘
                            │
              ┌─────────────┴─────────────┐
              ▼                            ▼
   ┌─────────────────────┐     ┌─────────────────────┐
   │ Metadata Recommender │     │  Content Improver    │
   └──────────┬───────────┘     └──────────┬───────────┘
              │                            │
              └─────────────┬──────────────┘
                             ▼
                  ┌─────────────────────┐
                  │  Reviewer / Critic   │
                  └──────────┬───────────┘
                             ▼
                       final_report
```

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

## Prerequisites

- Python 3.10+
- A [Groq API key](https://console.groq.com/keys) (required, free tier available — the agents use a Groq-hosted Llama model for reasoning)
- A [Tavily API key](https://tavily.com/) (optional — enables the web search tool; the pipeline runs without it, just with less positioning context)
- A GitHub personal access token (optional — raises the GitHub API rate limit from 60/hr to 5000/hr)

## Installation

```bash
git clone https://github.com/<you>/publication-assistant.git
cd publication-assistant
python -m venv .venv && source .venv/bin/activate   # optional but recommended
pip install -r requirements.txt
cp .env.example .env
# then edit .env and add your GROQ_API_KEY (and optionally TAVILY_API_KEY, GITHUB_TOKEN)
```

## Usage

```bash
python main.py --repo https://github.com/readytensor/rt_img_class_jn_resnet18_exampleA
```

Save the report to a file instead of just printing it:

```bash
python main.py --repo https://github.com/owner/repo --output report.md
```

### Sample output

```
Analyzing https://github.com/owner/repo ...

## Summary of Findings
This repo demonstrates a working image classifier but its README lacks
license and installation information, which will block adoption.

## Suggested Title & Summary
Title: ResNet18 Image Classifier — Reference Implementation
Summary: A minimal, reproducible ResNet18 training pipeline for image
classification, intended as a clear starting point for practitioners
learning the architecture.

## Suggested Tags
ResNet18, ImageClassification, PyTorch, DeepLearning, ComputerVision

## Missing Sections
- License — add a LICENSE file and reference it in the README
- Installation — add a "pip install -r requirements.txt" style section

## Overall Recommendation
Solid technical foundation; addressing the two missing sections above
would bring this to Essential-tier compliance.
```

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
pip install -r requirements.txt
pytest tests/ -v
```

## Design Decisions & Limitations

- **Why 4 agents, not fewer?** Repo analysis, metadata suggestion, content
  drafting, and review are genuinely different tasks with different failure
  modes — separating them keeps each agent's prompt focused and makes
  failures easier to isolate (see `errors` in the shared state).
- **Why LangGraph specifically?** The pipeline has a real fan-out/fan-in
  shape (two independent branches converging on the reviewer), which
  LangGraph's graph model expresses directly, rather than forcing a linear
  chain.
- **Known limitations:**
  - Only public GitHub repos are supported (no GitLab/Bitbucket, no private repos without a token with access).
  - The `readme_structure_checker` is regex/heading based — a README that
    documents installation steps in prose without a heading may be flagged
    as missing that section.
  - `Content Improver`'s suggestions are only as good as the web search
    context available; without `TAVILY_API_KEY` it drafts from the README alone.
  - No automated fact-checking agent yet — the Reviewer/Critic asks the LLM
    to ground claims in the README, but does not independently verify them.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Please run `pytest tests/` before submitting.
