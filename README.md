\# Publication Assistant for AI Projects



A LangGraph-orchestrated multi-agent system that reviews a public GitHub

repository and returns concrete suggestions for making it more discoverable,

clear, and complete before you publish it — built as a capstone project for

Ready Tensor's Mastering AI Agents certification.



\## Overview



You give it a GitHub repo URL. It gives back a report suggesting a better

title and summary, relevant tags, and exactly which standard documentation

sections (README structure, license, installation, etc.) are missing —

grounded in Ready Tensor's own \[Open Source Repository Guide](https://app.readytensor.ai)

Essential/Professional criteria, not just a generic opinion.



Four agents collaborate through a shared state object, coordinated by a

LangGraph graph:



```

&#x20;                ┌─────────────────────┐

&#x20;  repo\_url ───► │   Repo Analyzer      │

&#x20;                └──────────┬───────────┘

&#x20;                           │

&#x20;             ┌─────────────┴─────────────┐

&#x20;             ▼                            ▼

&#x20;  ┌─────────────────────┐     ┌─────────────────────┐

&#x20;  │ Metadata Recommender │     │  Content Improver    │

&#x20;  └──────────┬───────────┘     └──────────┬───────────┘

&#x20;             │                            │

&#x20;             └─────────────┬──────────────┘

&#x20;                            ▼

&#x20;                 ┌─────────────────────┐

&#x20;                 │  Reviewer / Critic   │

&#x20;                 └──────────┬───────────┘

&#x20;                            ▼

&#x20;                      final\_report

```



| Agent | Role | Tools used |

|---|---|---|

| \*\*Repo Analyzer\*\* | Fetches README, file structure, and repo metadata | `github\_repo\_reader` |

| \*\*Metadata Recommender\*\* | Suggests tags/keywords for the publication listing | `keyword\_extractor` |

| \*\*Content Improver\*\* | Drafts a better title/summary, checks how similar projects are positioned | `web\_search` |

| \*\*Reviewer / Critic\*\* | Checks README structure against Ready Tensor's documentation tiers, synthesizes the final report | `readme\_structure\_checker` |



`Metadata Recommender` and `Content Improver` run as parallel branches — neither

depends on the other's output, so running them concurrently cuts latency

without changing the result. `Reviewer / Critic` waits on both before

compiling the final report.



\## Target Audience



AI/ML practitioners preparing a project (GitHub repo) for public sharing —

on Ready Tensor, GitHub, or elsewhere — who want an objective first pass

before investing time in polishing it themselves.



\## Prerequisites



\- Python 3.10+

\- A \[Groq API key](https://console.groq.com/keys) (required, free tier available — the agents use a Groq-hosted Llama model for reasoning)

\- A \[Tavily API key](https://tavily.com/) (optional — enables the web search tool; the pipeline runs without it, just with less positioning context)

\- A GitHub personal access token (optional — raises the GitHub API rate limit from 60/hr to 5000/hr)



\## Installation



```bash

git clone https://github.com/<you>/publication-assistant.git

cd publication-assistant

python -m venv .venv \&\& source .venv/bin/activate   # optional but recommended

pip install -r requirements.txt

cp .env.example .env

\# then edit .env and add your GROQ\_API\_KEY (and optionally TAVILY\_API\_KEY, GITHUB\_TOKEN)

```



\## Usage



```bash

python main.py --repo https://github.com/joramkirubi/medical-rag-assistant

```



Every run automatically saves a timestamped markdown report under

`reports/<owner>\_<repo>\_<timestamp>.md`, in addition to printing it to the

console. Two optional flags change that behavior:



```bash

\# Save to a specific path instead of the auto-generated one

python main.py --repo https://github.com/owner/repo --output report.md



\# Skip saving entirely, just print to the console

python main.py --repo https://github.com/owner/repo --no-save

```



\### Sample output



```

Analyzing https://github.com/owner/repo ...



\## Summary of Findings

This repo demonstrates a working image classifier but its README lacks

license and installation information, which will block adoption.



\## Suggested Title \& Summary

Title: ResNet18 Image Classifier — Reference Implementation

Summary: A minimal, reproducible ResNet18 training pipeline for image

classification, intended as a clear starting point for practitioners

learning the architecture.



\## Suggested Tags

ResNet18, ImageClassification, PyTorch, DeepLearning, ComputerVision



\## Missing Sections

\- License — add a LICENSE file and reference it in the README

\- Installation — add a "pip install -r requirements.txt" style section



\## Overall Recommendation

Solid technical foundation; addressing the two missing sections above

would bring this to Essential-tier compliance.



✅ Report saved to reports/owner\_repo\_20260702-143012.md

```



\## Configuration



All configuration is via environment variables, loaded from `.env`

(see `.env.example`):



| Variable | Required | Purpose |

|---|---|---|

| `GROQ\_API\_KEY` | Yes | LLM calls for all four agents |

| `TAVILY\_API\_KEY` | No | Enables the `web\_search` tool |

| `GITHUB\_TOKEN` | No | Raises GitHub API rate limits |

| `MODEL\_NAME` | No | Defaults to `llama-3.3-70b-versatile` |

| `MODEL\_TEMPERATURE` | No | Defaults to `0.3` |



\## Testing



The tools and agent logic are covered by unit tests. Agent tests mock the

GitHub API and LLM calls so they run offline, without needing real API keys:



```bash

pip install -r requirements.txt

pytest tests/ -v

```



\## Design Decisions \& Limitations



\- \*\*Why 4 agents, not fewer?\*\* Repo analysis, metadata suggestion, content

&#x20; drafting, and review are genuinely different tasks with different failure

&#x20; modes — separating them keeps each agent's prompt focused and makes

&#x20; failures easier to isolate (see `errors` in the shared state).

\- \*\*Why LangGraph specifically?\*\* The pipeline has a real fan-out/fan-in

&#x20; shape (two independent branches converging on the reviewer), which

&#x20; LangGraph's graph model expresses directly, rather than forcing a linear

&#x20; chain.

\- \*\*A bug we hit and fixed:\*\* running two agents in parallel that both write

&#x20; to the same shared-state field (`errors`) caused a LangGraph

&#x20; `InvalidUpdateError`, since concurrent writes to one key need an explicit

&#x20; merge rule. Fixed by annotating that field with a reducer

&#x20; (`Annotated\[list\[str], operator.add]` in `src/state.py`) so concurrent

&#x20; writes concatenate instead of conflicting. A regression test in

&#x20; `tests/test\_agents\_with\_mocks.py` reproduces this exact scenario.

\- \*\*Evaluation:\*\* formal evaluation metrics (task success rate across a

&#x20; benchmark set of repos, structure-check precision/recall against

&#x20; hand-labeled examples) were considered as an optional enhancement per the

&#x20; capstone requirements, but were scoped out of this submission in favor of

&#x20; keeping the four core agents solid and well-tested. Noted here as a

&#x20; deliberate scope decision, not an oversight.

\- \*\*Known limitations:\*\*

&#x20; - Only public GitHub repos are supported (no GitLab/Bitbucket, no private repos without a token with access).

&#x20; - The `readme\_structure\_checker` is regex/heading based — a README that

&#x20;   documents installation steps in prose without a heading may be flagged

&#x20;   as missing that section.

&#x20; - `Content Improver`'s suggestions are only as good as the web search

&#x20;   context available; without `TAVILY\_API\_KEY` it drafts from the README alone.

&#x20; - No automated fact-checking agent yet — the Reviewer/Critic asks the LLM

&#x20;   to ground claims in the README, but does not independently verify them.



\## License



MIT — see \[LICENSE](LICENSE).



\## Contributing



Issues and PRs welcome. Please run `pytest tests/` before submitting.

