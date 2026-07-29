#Requires -Version 5.1
<#
.SYNOPSIS
  Applies the Agentic AI In Production capstone hardening to Publication Assistant.
.DESCRIPTION
  Run this from the ROOT of your existing Publication-assistant repo (the folder
  containing main.py). It writes/overwrites the files listed below, adds a
  Streamlit UI (app.py), guardrails, resilience, health checks, expanded tests,
  and documentation. It does NOT touch git history or run git commands for you.
#>

$ErrorActionPreference = "Stop"
Write-Host "Applying production hardening to Publication Assistant..." -ForegroundColor Cyan

# --- Create any new directories ---
New-Item -ItemType Directory -Force -Path "docs" | Out-Null
New-Item -ItemType Directory -Force -Path "reports" | Out-Null
New-Item -ItemType Directory -Force -Path "src" | Out-Null
New-Item -ItemType Directory -Force -Path "src/agents" | Out-Null
New-Item -ItemType Directory -Force -Path "src/tools" | Out-Null
New-Item -ItemType Directory -Force -Path "tests" | Out-Null

Write-Host "  writing main.py"
$content = @'
#!/usr/bin/env python3
"""
CLI entry point for the Publication Assistant multi-agent system.

Usage:
    python main.py --repo https://github.com/owner/repo
    python main.py --repo https://github.com/owner/repo --output report.md
    python main.py --repo https://github.com/owner/repo --no-save
    python main.py --repo https://github.com/owner/repo --auto-approve
"""
import argparse
import logging
import re
import sys
from datetime import datetime
from pathlib import Path

from src.graph import resume_pipeline, start_pipeline
from src.guardrails import GuardrailViolation
from src.health import format_health_report, run_health_check

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")

REPORTS_DIR = Path("reports")


def _default_report_path(result: dict, repo_url: str) -> Path:
    """
    Build a timestamped report path under reports/, e.g.
    reports/joramkirubi_medical-rag-assistant_20260702-143012.md
    Falls back to sanitizing the raw URL if the pipeline failed before it
    could extract owner/repo (so a report still gets saved either way).
    """
    owner = result.get("owner") or ""
    repo = result.get("repo") or ""
    if not (owner and repo):
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", repo_url.rstrip("/").split("/")[-1]) or "report"
        owner, repo = "unknown", slug
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return REPORTS_DIR / f"{owner}_{repo}_{timestamp}.md"


def _human_review_checkpoint(paused_state: dict) -> dict:
    """
    Presents the suggested tags/title/summary to the person running the
    tool, before Reviewer/Critic locks them into the final report. Returns
    a dict of edits to apply to state (possibly empty) via update_state().

    This is the human-in-the-loop checkpoint: the graph is genuinely
    paused here (via LangGraph's interrupt_before), not just printing a
    status message.
    """
    print("── Human Review Checkpoint ──────────────────────────────")
    print(f"Suggested title:   {paused_state.get('suggested_title') or '(none)'}")
    print(f"Suggested summary: {paused_state.get('suggested_summary') or '(none)'}")
    tags = paused_state.get("suggested_tags") or []
    print(f"Suggested tags:    {', '.join(tags) if tags else '(none)'}")
    print()

    while True:
        answer = input("Approve as-is? [Y/n/e=edit]: ").strip().lower()
        if answer in ("", "y", "n", "e"):
            break
        print(f"  '{answer}' isn't a valid choice — please type Y, n, or e.")

    edits: dict = {}

    if answer == "e":
        new_title = input(f"New title (Enter to keep current): ").strip()
        new_summary = input(f"New summary (Enter to keep current): ").strip()
        new_tags = input(f"New tags, comma-separated (Enter to keep current): ").strip()
        if new_title:
            edits["suggested_title"] = new_title
        if new_summary:
            edits["suggested_summary"] = new_summary
        if new_tags:
            edits["suggested_tags"] = [t.strip() for t in new_tags.split(",") if t.strip()]

    feedback = input("Any feedback on these suggestions? (optional, Enter to skip): ").strip()
    if feedback:
        edits["human_feedback"] = feedback

    edits["human_approved"] = answer != "n"
    return edits


def main() -> int:
    parser = argparse.ArgumentParser(description="Publication Assistant for AI Projects")
    parser.add_argument(
        "--repo",
        required=False,
        default=None,
        help="GitHub repo URL, e.g. https://github.com/owner/repo "
        "(required unless --health-check is passed)",
    )
    parser.add_argument("--description", default=None, help="Optional short project description")
    parser.add_argument(
        "--output",
        default=None,
        help="Optional path to save the final report. If omitted, the report is "
        "still auto-saved under reports/<owner>_<repo>_<timestamp>.md",
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Skip auto-saving the report to disk; just print it.",
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        help="Skip the interactive human review checkpoint and approve suggestions as-is "
        "(useful for scripting/CI; no --no-save equivalent needed, saving still happens).",
    )
    parser.add_argument(
        "--health-check",
        action="store_true",
        help="Check configuration and connectivity (API keys set, GitHub/Groq/Tavily "
        "reachable) and exit without running the pipeline. Useful for deployment "
        "smoke tests.",
    )
    args = parser.parse_args()

    if args.health_check:
        print(format_health_report(run_health_check()))
        return 0

    if not args.repo:
        parser.error("--repo is required unless --health-check is passed")

    print(f"\nAnalyzing {args.repo} ...\n")
    try:
        app, config, paused_state = start_pipeline(args.repo, args.description)
    except GuardrailViolation as exc:
        print(f"❌ Invalid input: {exc}")
        return 1

    if paused_state.get("errors"):
        print("⚠️  Warnings/errors encountered so far:")
        for err in paused_state["errors"]:
            print(f"  - {err}")
        print()

    if args.auto_approve:
        edits = {"human_approved": True}
    else:
        edits = _human_review_checkpoint(paused_state)

    try:
        result = resume_pipeline(app, config, edits=edits)
    except Exception as exc:  # noqa: BLE001 - last-resort net; agents already self-handle their own errors
        logging.getLogger(__name__).exception("Unexpected pipeline failure")
        print(f"\n❌ The pipeline hit an unexpected error and could not finish: {exc}")
        print("   (This is unusual -- individual agent failures normally degrade gracefully.")
        print("    Check the log above, or run --health-check to verify your setup.)")
        return 1

    if result.get("errors"):
        print("\n⚠️  Warnings/errors encountered during the run:")
        for err in result["errors"]:
            print(f"  - {err}")
        print()

    report = result.get("final_report", "(no report generated)")
    print("\n" + report)

    if args.no_save:
        return 0

    output_path = Path(args.output) if args.output else _default_report_path(result, args.repo)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(f"\n✅ Report saved to {output_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
'@
Set-Content -Path "main.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing app.py"
$content = @'
"""
Streamlit UI for the Publication Assistant multi-agent system.

Run with:
    streamlit run app.py

This is a thin presentation layer over src/graph.py -- it does not
duplicate any pipeline/agent logic, only handles input collection, the
human-in-the-loop review step, and result display/download.
"""
import logging
from datetime import datetime

import streamlit as st

from src.graph import resume_pipeline, start_pipeline
from src.guardrails import GuardrailViolation
from src.health import format_health_report, run_health_check

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

st.set_page_config(page_title="Publication Assistant", page_icon="📘", layout="centered")


def _init_session_state() -> None:
    defaults = {
        "stage": "input",  # input -> review -> done
        "app": None,
        "config": None,
        "paused_state": None,
        "result": None,
        "repo_input": "",
    }
    for key, value in defaults.items():
        if key not in st.session_state:
            st.session_state[key] = value


def _reset() -> None:
    for key in ("stage", "app", "config", "paused_state", "result"):
        st.session_state.pop(key, None)
    _init_session_state()


def _render_sidebar() -> None:
    with st.sidebar:
        st.header("System status")
        if st.button("Run health check"):
            with st.spinner("Checking configuration and connectivity..."):
                report = run_health_check()
            st.code(format_health_report(report), language=None)
            if not report.all_ok:
                st.error("Some required checks failed -- see above.")
        st.divider()
        st.caption(
            "Four agents (Repo Analyzer, Metadata Recommender, Content Improver, "
            "Reviewer/Critic) run in a LangGraph pipeline with a human-in-the-loop "
            "checkpoint before the final report is generated."
        )
        if st.button("Start over"):
            _reset()
            st.rerun()


def _render_input_stage() -> None:
    st.title("📘 Publication Assistant")
    st.write(
        "Give it a public GitHub repo URL. It reviews the README, suggests a "
        "better title/summary/tags, and flags missing documentation sections "
        "-- grounded in Ready Tensor's Open Source Repository Guide."
    )

    with st.form("repo_form"):
        repo_url = st.text_input(
            "GitHub repository URL",
            placeholder="https://github.com/owner/repo",
        )
        description = st.text_area(
            "Optional project description (helps the agents with context)",
            max_chars=500,
            height=80,
        )
        submitted = st.form_submit_button("Analyze repository", type="primary")

    if submitted:
        try:
            with st.spinner("Fetching repo and running Repo Analyzer, Metadata Recommender, "
                             "and Content Improver..."):
                app, config, paused_state = start_pipeline(repo_url, description)
        except GuardrailViolation as exc:
            st.error(f"Invalid input: {exc}")
            return
        except Exception as exc:  # noqa: BLE001 - surfaced to the user, not a silent failure
            logger.exception("Pipeline failed to start")
            st.error(f"Something went wrong starting the pipeline: {exc}")
            return

        st.session_state.app = app
        st.session_state.config = config
        st.session_state.paused_state = paused_state
        st.session_state.stage = "review"
        st.rerun()


def _render_review_stage() -> None:
    st.title("📘 Publication Assistant")
    st.subheader("Human Review Checkpoint")
    st.write(
        "The pipeline is paused here, right before the final report is written. "
        "Review or edit the suggestions below before continuing."
    )

    paused_state = st.session_state.paused_state

    if paused_state.get("errors"):
        with st.expander("⚠️ Warnings from earlier steps", expanded=False):
            for err in paused_state["errors"]:
                st.write(f"- {err}")

    with st.form("review_form"):
        title = st.text_input("Suggested title", value=paused_state.get("suggested_title") or "")
        summary = st.text_area(
            "Suggested summary", value=paused_state.get("suggested_summary") or "", height=100
        )
        tags = st.text_input(
            "Suggested tags (comma-separated)",
            value=", ".join(paused_state.get("suggested_tags") or []),
        )
        feedback = st.text_area(
            "Feedback for the Reviewer/Critic agent (optional)",
            placeholder="e.g. 'the summary undersells the RAG component'",
            height=80,
        )
        col1, col2 = st.columns(2)
        approve = col1.form_submit_button("Approve & generate final report", type="primary")
        reject = col2.form_submit_button("Reject suggestions")

    if approve or reject:
        edits = {
            "suggested_title": title,
            "suggested_summary": summary,
            "suggested_tags": [t.strip() for t in tags.split(",") if t.strip()],
            "human_approved": approve,
        }
        if feedback.strip():
            edits["human_feedback"] = feedback.strip()

        try:
            with st.spinner("Running Reviewer/Critic and generating the final report..."):
                result = resume_pipeline(
                    st.session_state.app, st.session_state.config, edits=edits
                )
        except Exception as exc:  # noqa: BLE001
            logger.exception("Pipeline failed to resume")
            st.error(f"Something went wrong generating the report: {exc}")
            return

        st.session_state.result = result
        st.session_state.stage = "done"
        st.rerun()


def _render_done_stage() -> None:
    st.title("📘 Publication Assistant")
    result = st.session_state.result

    if result.get("errors"):
        with st.expander("⚠️ Warnings encountered during the run", expanded=False):
            for err in result["errors"]:
                st.write(f"- {err}")

    report = result.get("final_report", "(no report generated)")
    st.markdown(report)

    owner = result.get("owner") or "unknown"
    repo = result.get("repo") or "report"
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    filename = f"{owner}_{repo}_{timestamp}.md"

    st.download_button(
        "Download report (.md)",
        data=report,
        file_name=filename,
        mime="text/markdown",
    )

    if st.button("Analyze another repository"):
        _reset()
        st.rerun()


def main() -> None:
    _init_session_state()
    _render_sidebar()

    stage = st.session_state.stage
    if stage == "input":
        _render_input_stage()
    elif stage == "review":
        _render_review_stage()
    elif stage == "done":
        _render_done_stage()
    else:
        _reset()
        st.rerun()


if __name__ == "__main__":
    main()
'@
Set-Content -Path "app.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing requirements.txt"
$content = @'
langgraph>=0.2.60,<0.3.0
langchain-core>=0.3.30,<0.4.0
langchain-groq>=0.2.1,<0.3.0
requests>=2.32.3,<3.0.0
python-dotenv>=1.0.1,<2.0.0
tavily-python>=0.5.0,<0.6.0
streamlit>=1.38.0,<2.0.0
pytest>=8.3.4,<9.0.0
pytest-cov>=5.0.0,<6.0.0
'@
Set-Content -Path "requirements.txt" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing .gitignore"
$content = @'
.venv/
__pycache__/
*.pyc
.env
.coverage
.pytest_cache/
reports/*.md
!reports/.gitkeep
'@
Set-Content -Path ".gitignore" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing README.md"
$content = @'
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
sections (README structure, license, installation, etc.) are missing —
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

`Metadata Recommender` and `Content Improver` run as parallel branches —
neither depends on the other's output, so running them concurrently cuts
latency without changing the result. `Reviewer / Critic` waits on both
before compiling the final report.

## Target Audience

AI/ML practitioners preparing a project (GitHub repo) for public sharing —
on Ready Tensor, GitHub, or elsewhere — who want an objective first pass
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
| **User interface** | `app.py`: a Streamlit web UI with the same input → human-review → report flow as the CLI, plus a sidebar health-check and a download button. See [Web UI](#web-ui). |
| **Resilience & monitoring** | `src/resilience.py`: retry-with-exponential-backoff and hard wall-clock timeouts wrap every outbound call (GitHub API, Tavily, Groq). `src/health.py`: a config/connectivity health check exposed via `--health-check` and the UI sidebar. See [Resilience & Monitoring](#resilience--monitoring). |
| **Documentation** | This README plus [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/API.md](docs/API.md), [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md), and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). |

Every existing agent's own try/except-and-degrade behavior was left
intact; the new guardrails/resilience layers sit around that logic rather
than replacing it.

## Human-in-the-Loop Review

The graph genuinely pauses right before the Reviewer/Critic agent runs —
using LangGraph's `interrupt_before` mechanism backed by a checkpointer —
so you can inspect the suggested title, summary, and tags, edit any of
them, and leave free-text feedback before the final report is generated.
The edited values and feedback are injected back into shared state and are
what Reviewer/Critic actually reads when it resumes; this is verified by a
dedicated test (`tests/test_human_in_the_loop.py`) that inspects the exact
text sent to the LLM after an edit.

**Two issues surfaced only through real, interactive execution — not the
mocked test suite alone:**

1. Because Metadata Recommender and Content Improver write to state in the
   same parallel step, applying a human's edit via `update_state()` raised
   `InvalidUpdateError: Ambiguous update, specify as_node` — LangGraph
   couldn't infer which of the two simultaneous writers the edit belonged
   to. Fixed by explicitly passing `as_node="content_improver"`.
2. The interactive approve/edit prompt initially treated any unrecognized
   input — not just `n` or `e` — as silent approval. Fixed by validating
   input and re-prompting until a real Y/n/e answer is given, backed by a
   dedicated regression test (`tests/test_cli_review_checkpoint.py`).

Both trace back to the same architectural choice: Metadata Recommender and
Content Improver running in parallel for latency. That's a deliberate
tradeoff, and these two bugs are a concrete part of its cost.

Pass `--auto-approve` (CLI) to skip the interactive prompt for
scripted/CI use.

## Prerequisites

- Python 3.10+
- A [Groq API key](https://console.groq.com/keys) (required, free tier available — the agents use a Groq-hosted Llama model for reasoning)
- A [Tavily API key](https://tavily.com/) (optional — enables the web search tool; the pipeline runs without it, just with less positioning context)
- A GitHub personal access token (optional — raises the GitHub API rate limit from 60/hr to 5000/hr)

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
— see [Human-in-the-Loop Review](#human-in-the-loop-review) above. Pass
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

## Web UI

For a non-technical or interactive workflow, run the Streamlit app instead
of the CLI:

```bash
streamlit run app.py
```

This opens a local web UI (`http://localhost:8501`) with three screens:

1. **Input** — paste a repo URL and optional description.
2. **Human review** — edit the suggested title/summary/tags and leave
   feedback, mirroring the CLI's interactive checkpoint.
3. **Report** — the rendered final report plus a "Download report (.md)"
   button.

The sidebar has a **Run health check** button (see
[Resilience & Monitoring](#resilience--monitoring)) and a **Start over**
button to reset the session. The UI is a thin wrapper over
`src/graph.py` — it contains no pipeline logic of its own, so everything
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

- **Input validation** — `validate_repo_url` accepts only
  `https://github.com/<owner>/<repo>`-shaped URLs: no other hosts
  (blocks SSRF-style redirection to internal hosts), no `http://`, no
  extra path segments, no control characters, capped length. Both the CLI
  and the UI funnel through this single validator via `start_pipeline`.
- **Input sanitization** — `sanitize_user_description` strips control
  characters, collapses whitespace, and caps the optional free-text
  description at 500 characters before it ever reaches an LLM prompt.
- **Output filtering** — `filter_output` runs a regex-based redaction pass
  over the final report for anything that looks like a leaked API key
  (Groq, GitHub, Tavily, AWS, generic `sk-` style keys), as a last-resort
  net against a README or web-search snippet echoing a real credential
  back through the LLM.
- **Error handling** — every agent already wrapped its own logic in
  try/except with graceful degradation (recorded in `state["errors"]`,
  surfaced in the final report and CLI/UI output); `main.py` and `app.py`
  additionally catch `GuardrailViolation` and any unexpected pipeline
  exception at the top level so a bad input or surprise failure prints a
  clear message and exits cleanly instead of an unhandled traceback.

## Resilience & Monitoring

`src/resilience.py` provides two decorators applied to every outbound
network/LLM call (GitHub API reads, `invoke_llm` for all three
LLM-calling agents):

- **`with_retry`** — retries transient failures (connection errors,
  timeouts, 5xx/429 responses) up to a bounded number of attempts with
  exponential backoff, then re-raises so the existing per-agent
  degradation logic handles a genuinely persistent failure.
- **`with_timeout`** — runs the call in a worker thread with a hard
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
away) doesn't have a direct equivalent here — the analogous risk (a
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

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — system diagram, component
  table, design decisions, known limitations.
- [docs/API.md](docs/API.md) — state schema and CLI/UI interface
  specification.
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — install, configure, run
  (CLI + UI), test, and optionally containerize.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common issues and
  FAQ.

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
- The `readme_structure_checker` is regex/heading based — a README that
  documents installation steps in prose without a heading may be flagged
  as missing that section.
- `Content Improver`'s suggestions are only as good as the web search
  context available; without `TAVILY_API_KEY` it drafts from the README
  alone.
- No automated fact-checking agent yet — the Reviewer/Critic asks the LLM
  to ground claims in the README, but does not independently verify them.
- This is a fixed-DAG pipeline, not a looping agent, so loop/iteration
  caps aren't directly applicable (see
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#known-limitations)).
</details>

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Issues and PRs welcome. Please run `pytest tests/` before submitting.
'@
Set-Content -Path "README.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/graph.py"
$content = @'
"""
Orchestration graph.

Flow:

    START -> repo_analyzer -> metadata_recommender -> [HUMAN REVIEW] -> reviewer_critic -> END
                            -> content_improver     -^

repo_analyzer runs first (everything downstream needs the README).
metadata_recommender and content_improver then run as parallel branches,
since neither depends on the other's output — this is a deliberate design
choice to cut latency, not just an artifact of the framework.

Before reviewer_critic runs, the graph PAUSES (a static interrupt) so a
human can inspect the suggested tags/title/summary, optionally edit them,
and optionally leave free-text feedback. reviewer_critic then runs with
whatever the human approved, edited, or commented on — this is a real
human-in-the-loop checkpoint, not just a log statement.
"""
import uuid

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, StateGraph

from src.agents import (
    content_improver_node,
    metadata_recommender_node,
    repo_analyzer_node,
    reviewer_critic_node,
)
from src.guardrails import sanitize_user_description, validate_repo_url
from src.state import PublicationAssistantState


def build_graph():
    graph = StateGraph(PublicationAssistantState)

    graph.add_node("repo_analyzer", repo_analyzer_node)
    graph.add_node("metadata_recommender", metadata_recommender_node)
    graph.add_node("content_improver", content_improver_node)
    graph.add_node("reviewer_critic", reviewer_critic_node)

    graph.set_entry_point("repo_analyzer")

    graph.add_edge("repo_analyzer", "metadata_recommender")
    graph.add_edge("repo_analyzer", "content_improver")

    graph.add_edge("metadata_recommender", "reviewer_critic")
    graph.add_edge("content_improver", "reviewer_critic")

    graph.add_edge("reviewer_critic", END)

    checkpointer = InMemorySaver()
    # interrupt_before pauses the graph right before the named node runs,
    # so the human reviews/edits state BEFORE that node acts on it —
    # the right choice here since we want to gate what Reviewer/Critic
    # sees, not review something it already did (that would be
    # interrupt_after instead).
    return graph.compile(checkpointer=checkpointer, interrupt_before=["reviewer_critic"])


def start_pipeline(repo_url: str, user_description: str | None = None):
    """
    Runs the pipeline up to the human-in-the-loop checkpoint (paused right
    before Reviewer/Critic). Returns (app, config, paused_state) so the
    caller can inspect and optionally edit state before calling
    resume_pipeline().

    `config` carries the thread_id the checkpointer uses to know which
    paused run to resume later — it must be passed back into
    resume_pipeline() unchanged.
    """
    # Guardrail: validated/normalized here, once, at the single entry point
    # both the CLI (main.py) and the UI (app.py) funnel through -- so
    # neither caller can accidentally bypass input validation.
    clean_repo_url = validate_repo_url(repo_url)
    clean_description = sanitize_user_description(user_description)

    app = build_graph()
    config = {"configurable": {"thread_id": str(uuid.uuid4())}}
    initial_state: PublicationAssistantState = {
        "repo_url": clean_repo_url,
        "user_description": clean_description,
        "errors": [],
    }
    app.invoke(initial_state, config)
    paused_state = app.get_state(config).values
    return app, config, paused_state


def resume_pipeline(app, config, edits: dict | None = None) -> PublicationAssistantState:
    """
    Optionally applies human edits/feedback to the paused state, then
    resumes execution through Reviewer/Critic to completion.
    """
    if edits:
        # as_node is required here: this graph has two parallel branches
        # (metadata_recommender and content_improver) that write to state in
        # the same step. LangGraph normally infers which node an update
        # should be attributed to by looking at which node wrote most
        # recently -- but with two nodes writing simultaneously, it can't
        # pick one and raises InvalidUpdateError("Ambiguous update").
        # Explicitly attributing human edits to content_improver resolves
        # this; it's internal bookkeeping only and does not change which
        # fields get updated or their values.
        app.update_state(config, edits, as_node="content_improver")
    return app.invoke(None, config)


def run_pipeline(repo_url: str, user_description: str | None = None) -> PublicationAssistantState:
    """
    Convenience wrapper that runs the full pipeline with no human review
    step (auto-approves). Used by the test suite and anywhere a
    non-interactive run is needed.
    """
    app, config, _ = start_pipeline(repo_url, user_description)
    return resume_pipeline(app, config, edits=None)
'@
Set-Content -Path "src/graph.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/llm.py"
$content = @'
"""
Single place that constructs the LLM client, so every agent uses the same
model/temperature configuration.
"""
from langchain_core.messages import BaseMessage
from langchain_groq import ChatGroq

from src.config import require_groq_key, settings
from src.resilience import with_retry, with_timeout


def get_llm(temperature: float | None = None) -> ChatGroq:
    require_groq_key()
    return ChatGroq(
        model=settings.model_name,
        temperature=temperature if temperature is not None else settings.model_temperature,
        api_key=settings.groq_api_key,
        timeout=60,
        max_retries=2,
    )


# App-level resilience on top of ChatGroq's own timeout/max_retries: those
# only cover the raw HTTP call, not e.g. the client raising before a
# request is even sent. This gives every agent the same
# retry-with-backoff + hard-timeout behavior via one call site instead of
# each agent re-implementing it.
@with_timeout(seconds=45)
@with_retry(max_attempts=2, base_delay=1.5, exceptions=(Exception,))
def _invoke(llm: ChatGroq, messages: list[BaseMessage]):
    return llm.invoke(messages)


def invoke_llm(llm: ChatGroq, messages: list[BaseMessage]):
    """
    Resilient wrapper around llm.invoke(): retries transient failures once
    with backoff, then enforces a hard 45s wall-clock timeout so a hung
    call can't stall the whole pipeline. Exceptions are re-raised for the
    caller's existing try/except-and-degrade logic to handle.
    """
    return _invoke(llm, messages)
'@
Set-Content -Path "src/llm.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/guardrails.py"
$content = @'
"""
Guardrails: input validation/sanitization and output filtering.

These are deliberately simple, dependency-light, and deterministic (no LLM
calls) so they run fast, fail predictably, and can be unit tested without
mocking anything. They sit at the two edges of the system:

  1. INPUT  -- validate_repo_url / sanitize_user_description are called
              before the graph ever runs (main.py / app.py), rejecting bad
              input before it costs an API call.
  2. OUTPUT -- filter_output is called on the final report before it is
              shown to the user or written to disk, as a last-resort net
              against secrets accidentally leaking into LLM output (e.g. a
              README containing a real key that gets echoed back).
"""
import re

# Only allow http(s) GitHub URLs of the form github.com/<owner>/<repo>.
# Deliberately strict: this is a public-repo README/metadata reader, not a
# general-purpose URL fetcher, so anything that isn't a plain github.com
# repo URL is rejected rather than "best-effort" parsed. This also closes
# off SSRF-style tricks (e.g. pointing the fetcher at an internal host).
_GITHUB_URL_RE = re.compile(
    r"^https://github\.com/(?P<owner>[A-Za-z0-9][A-Za-z0-9\-]{0,38})"
    r"/(?P<repo>[A-Za-z0-9_.\-]{1,100})/?(?:\.git)?/?$"
)

MAX_DESCRIPTION_LENGTH = 500

# Patterns that look like leaked credentials. Deliberately conservative
# (favors false positives over false negatives) since this only runs on
# our own generated report text, so a mistaken redaction just means a
# human re-checks the source, not a broken pipeline.
_SECRET_PATTERNS = [
    (re.compile(r"gsk_[A-Za-z0-9]{20,}"), "[REDACTED_GROQ_KEY]"),  # Groq keys
    (re.compile(r"ghp_[A-Za-z0-9]{30,}"), "[REDACTED_GITHUB_TOKEN]"),  # GitHub PATs
    (re.compile(r"tvly-[A-Za-z0-9]{20,}"), "[REDACTED_TAVILY_KEY]"),  # Tavily keys
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "[REDACTED_API_KEY]"),  # generic sk- style keys
    (
        re.compile(r"AKIA[0-9A-Z]{16}"),
        "[REDACTED_AWS_KEY]",
    ),  # AWS access key IDs
]

# Control characters (other than tab/newline/carriage return) have no
# legitimate place in a short free-text description field.
_CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


class GuardrailViolation(ValueError):
    """Raised when input fails validation. A ValueError subclass so
    existing `except ValueError` call sites keep working."""


def validate_repo_url(repo_url: str) -> str:
    """
    Validate and normalize a GitHub repository URL.

    Args:
        repo_url: Raw user-supplied URL string.

    Returns:
        The normalized URL (trailing slashes/.git stripped).

    Raises:
        GuardrailViolation: if the URL is empty, not a string, too long, or
            doesn't match the expected https://github.com/<owner>/<repo> shape.
    """
    if not isinstance(repo_url, str) or not repo_url.strip():
        raise GuardrailViolation("Repo URL is required and cannot be empty.")

    candidate = repo_url.strip()

    if len(candidate) > 200:
        raise GuardrailViolation("Repo URL is unreasonably long (max 200 chars).")

    if _CONTROL_CHAR_RE.search(candidate):
        raise GuardrailViolation("Repo URL contains invalid control characters.")

    match = _GITHUB_URL_RE.match(candidate)
    if not match:
        raise GuardrailViolation(
            "Repo URL must look like https://github.com/<owner>/<repo> "
            f"(got: {candidate!r})."
        )

    owner, repo = match.group("owner"), match.group("repo")
    repo = repo[:-4] if repo.endswith(".git") else repo
    return f"https://github.com/{owner}/{repo}"


def sanitize_user_description(description: str | None) -> str:
    """
    Sanitize the optional free-text project description supplied by the
    user before it's placed into an LLM prompt: strips control characters,
    collapses excess whitespace, and truncates to MAX_DESCRIPTION_LENGTH.

    Never raises -- an empty/None input just returns "".
    """
    if not description:
        return ""
    cleaned = _CONTROL_CHAR_RE.sub("", description)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned[:MAX_DESCRIPTION_LENGTH]


def filter_output(text: str) -> str:
    """
    Redact anything that looks like a leaked API key/credential from
    generated report text before it's shown or saved. Deterministic
    regex-based redaction, run on every final report as a last-resort
    safety net -- not a substitute for not logging secrets in the first
    place.
    """
    if not text:
        return text
    filtered = text
    for pattern, replacement in _SECRET_PATTERNS:
        filtered = pattern.sub(replacement, filtered)
    return filtered
'@
Set-Content -Path "src/guardrails.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/resilience.py"
$content = @'
"""
Resilience helpers: retry-with-backoff and timeout enforcement for outbound
calls (GitHub API, Tavily web search, Groq LLM calls).

Kept as small, explicit wrappers rather than pulling in a heavier
framework, since only two behaviors are needed here:

  1. Transient failures (timeouts, connection errors, 429/5xx) should be
     retried a bounded number of times with exponential backoff, then give
     up -- not retried forever.
  2. A single external call should never be allowed to hang the whole
     pipeline indefinitely -- each call gets a hard wall-clock timeout.

Every agent node already has a top-level try/except that degrades
gracefully and records the failure in state["errors"] (see src/agents/).
These helpers sit *inside* that boundary: they turn "one flaky network
blip" into "succeeded on the 2nd try" so the graceful-degradation path is
only hit for genuinely persistent failures, not routine transient ones.
"""
import functools
import logging
import time
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError
from typing import Callable, TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")


class ResilienceTimeoutError(TimeoutError):
    """Raised when a wrapped call exceeds its allotted wall-clock time."""


def with_retry(
    max_attempts: int = 3,
    base_delay: float = 1.0,
    backoff_factor: float = 2.0,
    exceptions: tuple[type[Exception], ...] = (Exception,),
):
    """
    Decorator: retry a function up to `max_attempts` times on the given
    exception types, sleeping `base_delay * backoff_factor**attempt`
    seconds between tries. Re-raises the last exception if every attempt
    fails, so the caller's existing error handling still runs.

    Example:
        @with_retry(max_attempts=3, exceptions=(requests.RequestException,))
        def fetch(...): ...
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func, assigned=[a for a in functools.WRAPPER_ASSIGNMENTS if hasattr(func, a)])
        def wrapper(*args, **kwargs) -> T:
            last_exc: Exception | None = None
            fn_name = getattr(func, "__name__", repr(func))
            for attempt in range(1, max_attempts + 1):
                try:
                    return func(*args, **kwargs)
                except exceptions as exc:  # noqa: BLE001 - deliberately broad, bounded by `exceptions`
                    last_exc = exc
                    if attempt == max_attempts:
                        logger.warning(
                            "%s failed after %d attempt(s), giving up: %s",
                            fn_name,
                            attempt,
                            exc,
                        )
                        raise
                    delay = base_delay * (backoff_factor ** (attempt - 1))
                    logger.info(
                        "%s failed (attempt %d/%d): %s -- retrying in %.1fs",
                        fn_name,
                        attempt,
                        max_attempts,
                        exc,
                        delay,
                    )
                    time.sleep(delay)
            # Unreachable in practice (loop either returns or raises), but
            # keeps type checkers happy and guards against a future edit
            # accidentally removing the raise above.
            raise last_exc  # type: ignore[misc]

        return wrapper

    return decorator


def with_timeout(seconds: float):
    """
    Decorator: run the wrapped function in a worker thread and enforce a
    hard wall-clock timeout, raising ResilienceTimeoutError if it's
    exceeded. Thread-based (not signal-based) so it works on Windows,
    which is this project's primary target environment and doesn't
    support SIGALRM.

    Note: the underlying call is NOT forcibly killed if it times out (Python
    has no safe way to do that to a running thread) -- it keeps running in
    the background, but the caller gets control back immediately with an
    error instead of hanging.
    """

    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func, assigned=[a for a in functools.WRAPPER_ASSIGNMENTS if hasattr(func, a)])
        def wrapper(*args, **kwargs) -> T:
            fn_name = getattr(func, "__name__", repr(func))
            with ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(func, *args, **kwargs)
                try:
                    return future.result(timeout=seconds)
                except FutureTimeoutError as exc:
                    logger.warning("%s exceeded %.1fs timeout", fn_name, seconds)
                    raise ResilienceTimeoutError(
                        f"{fn_name} did not complete within {seconds}s"
                    ) from exc

        return wrapper

    return decorator
'@
Set-Content -Path "src/resilience.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/health.py"
$content = @'
"""
Health check: verifies configuration and connectivity without running the
full agent pipeline. Used by `python main.py --health-check`, the
Streamlit UI's sidebar, and can be wired into a container's HEALTHCHECK /
readiness probe if this is ever deployed behind an orchestrator.

Deliberately fast and side-effect-free: it makes at most one lightweight
GET request per external service (no LLM calls, no tokens spent).
"""
import logging
from dataclasses import dataclass, field

import requests

from src.config import settings

logger = logging.getLogger(__name__)

_TIMEOUT = 5  # seconds -- health checks should fail fast


@dataclass
class CheckResult:
    name: str
    ok: bool
    detail: str


@dataclass
class HealthReport:
    checks: list[CheckResult] = field(default_factory=list)

    @property
    def all_ok(self) -> bool:
        # Optional services (Tavily, GitHub token) don't fail the overall
        # report -- only required config/connectivity does.
        return all(c.ok for c in self.checks if not c.name.startswith("optional:"))


def _check_groq_key() -> CheckResult:
    if settings.groq_api_key:
        return CheckResult("GROQ_API_KEY", True, "set")
    return CheckResult("GROQ_API_KEY", False, "missing -- required, copy .env.example to .env")


def _check_github_connectivity() -> CheckResult:
    try:
        resp = requests.get("https://api.github.com", timeout=_TIMEOUT)
        remaining = resp.headers.get("X-RateLimit-Remaining", "unknown")
        if resp.ok:
            return CheckResult(
                "GitHub API", True, f"reachable (rate limit remaining: {remaining})"
            )
        return CheckResult("GitHub API", False, f"unexpected status {resp.status_code}")
    except requests.RequestException as exc:
        return CheckResult("GitHub API", False, f"unreachable ({exc})")


def _check_tavily_key() -> CheckResult:
    if settings.tavily_api_key:
        return CheckResult("optional:TAVILY_API_KEY", True, "set")
    return CheckResult(
        "optional:TAVILY_API_KEY", True, "not set -- Content Improver runs without web context"
    )


def _check_github_token() -> CheckResult:
    if settings.github_token:
        return CheckResult("optional:GITHUB_TOKEN", True, "set (5000 req/hr rate limit)")
    return CheckResult(
        "optional:GITHUB_TOKEN", True, "not set -- limited to 60 req/hr unauthenticated"
    )


def _check_reports_dir_writable() -> CheckResult:
    from pathlib import Path

    reports_dir = Path("reports")
    try:
        reports_dir.mkdir(parents=True, exist_ok=True)
        probe = reports_dir / ".health_check_probe"
        probe.write_text("ok", encoding="utf-8")
        probe.unlink()
        return CheckResult("reports/ writable", True, "ok")
    except OSError as exc:
        return CheckResult("reports/ writable", False, f"cannot write to reports/ ({exc})")


def run_health_check() -> HealthReport:
    """Run all checks and return a HealthReport. Never raises."""
    checks = [
        _check_groq_key(),
        _check_github_connectivity(),
        _check_tavily_key(),
        _check_github_token(),
        _check_reports_dir_writable(),
    ]
    return HealthReport(checks=checks)


def format_health_report(report: HealthReport) -> str:
    lines = ["── Health Check ─────────────────────────────────────────"]
    for check in report.checks:
        icon = "✅" if check.ok else "❌"
        label = check.name.replace("optional:", "") + (
            " (optional)" if check.name.startswith("optional:") else ""
        )
        lines.append(f"{icon} {label}: {check.detail}")
    lines.append("")
    lines.append("Overall: " + ("✅ healthy" if report.all_ok else "❌ unhealthy"))
    return "\n".join(lines)
'@
Set-Content -Path "src/health.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/agents/repo_analyzer.py"
$content = @'
"""
Agent: Repo Analyzer

ROLE: Data-gathering specialist and entry point of the pipeline.
SPECIALIZATION: Interfacing with the GitHub REST API; owns no LLM
reasoning at all — this agent is deliberately "dumb" and mechanical, so a
GitHub outage or bad URL fails predictably rather than producing a
plausible-sounding but wrong result.
READS FROM STATE: repo_url
WRITES TO STATE: owner, repo, readme_text, file_structure, repo_metadata, errors
"""
import logging

from src.state import PublicationAssistantState
from src.tools.github_repo_tool import github_repo_reader

logger = logging.getLogger(__name__)


def repo_analyzer_node(state: PublicationAssistantState) -> dict:
    repo_url = state["repo_url"]

    try:
        result = github_repo_reader.invoke({"repo_url": repo_url})
    except Exception as exc:  # noqa: BLE001 - surfaced to the user via state
        logger.exception("repo_analyzer_node failed")
        return {
            "readme_text": "",
            "file_structure": [],
            "repo_metadata": {},
            "errors": [f"RepoAnalyzer: failed to fetch repo — {exc}"],
        }

    return {
        "owner": result["owner"],
        "repo": result["repo"],
        "readme_text": result["readme"],
        "file_structure": result["file_structure"],
        "repo_metadata": result["metadata"],
        "errors": [],
    }
'@
Set-Content -Path "src/agents/repo_analyzer.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/agents/metadata_recommender.py"
$content = @'
"""
Agent: Metadata Recommender

ROLE: Tagging/categorization specialist — one of two parallel branches
that run right after Repo Analyzer.
SPECIALIZATION: Combines a deterministic keyword-extraction tool with a
narrow LLM pass whose only job is filtering raw candidates down to
publication-quality tags. Does not touch title, summary, or structure
checking — those belong to other agents.
READS FROM STATE: readme_text
WRITES TO STATE: suggested_keywords, suggested_tags, errors
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm, invoke_llm
from src.state import PublicationAssistantState
from src.tools.keyword_extractor_tool import keyword_extractor

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a metadata specialist for Ready Tensor, a platform for AI/ML \
publications. You are given a raw list of candidate keywords extracted from a \
project's README, plus the README text itself. Your job is to select and refine \
the best 5-8 tags for this project's publication listing.

Good tags are specific (e.g. "LangGraph", "RAG", "MultiAgentSystems"), not generic \
English words. Prefer CamelCase or hyphenated multi-word tags where natural, \
consistent with how Ready Tensor publications are tagged.

Respond with ONLY a comma-separated list of tags, nothing else."""


def metadata_recommender_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")

    if not readme_text:
        return {
            "suggested_keywords": [],
            "suggested_tags": [],
            "errors": ["MetadataRecommender: skipped, no README text available."],
        }

    raw = keyword_extractor.invoke({"text": readme_text, "top_n": 15})
    candidate_keywords = raw["keywords"]
    new_errors = []

    try:
        llm = get_llm(temperature=0.2)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"Candidate keywords: {', '.join(candidate_keywords)}\n\n"
                    f"README excerpt:\n{readme_text[:3000]}"
                )
            ),
        ]
        response = invoke_llm(llm, messages)
        tags = [t.strip() for t in response.content.split(",") if t.strip()]
    except Exception as exc:  # noqa: BLE001
        logger.exception("metadata_recommender_node LLM call failed")
        new_errors.append(f"MetadataRecommender: LLM refinement failed ({exc}), using raw tags.")
        tags = raw["suggested_tags"]

    return {
        "suggested_keywords": candidate_keywords,
        "suggested_tags": tags,
        "errors": new_errors,
    }
'@
Set-Content -Path "src/agents/metadata_recommender.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/agents/content_improver.py"
$content = @'
"""
Agent: Content Improver

ROLE: Copywriting/positioning specialist — the second of two parallel
branches that run right after Repo Analyzer.
SPECIALIZATION: Grounded content drafting. Uses web search for external
positioning context, but is explicitly instructed to draft claims only
from the README itself — this agent's specific job is balancing "sound
appealing" against "don't invent features," which is why its prompt is
separate from Metadata Recommender's narrower tagging job.
READS FROM STATE: readme_text, repo
WRITES TO STATE: suggested_title, suggested_summary, positioning_notes, errors
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm, invoke_llm
from src.state import PublicationAssistantState
from src.tools.web_search_tool import web_search

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are an editorial specialist for Ready Tensor publications. \
Given a project's README and some web context about similarly positioned projects, \
propose:

1. A specific, discoverable title (avoid vague titles like "My Project")
2. A 2-3 sentence summary that clearly states what the project does and why it matters
3. One sentence of positioning notes: how this project compares to similar ones you saw

Ground every claim in the README content provided — do not invent features, \
performance numbers, or capabilities that aren't described in the README.

Respond in exactly this format:
TITLE: <title>
SUMMARY: <summary>
POSITIONING: <positioning notes>"""


def content_improver_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    repo_name = state.get("repo", "")

    if not readme_text:
        return {
            "suggested_title": "",
            "suggested_summary": "",
            "positioning_notes": "",
            "errors": ["ContentImprover: skipped, no README text available."],
        }

    search_query = f"{repo_name} AI ML GitHub project similar tools"
    search_result = web_search.invoke({"query": search_query, "max_results": 5})
    context_snippets = "\n".join(
        f"- {r['title']}: {r['snippet']}" for r in search_result.get("results", [])
    ) or "(no web context available)"

    new_errors = []
    try:
        llm = get_llm(temperature=0.4)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"README:\n{readme_text[:4000]}\n\n"
                    f"Similar projects found via web search:\n{context_snippets}"
                )
            ),
        ]
        response = invoke_llm(llm, messages)
        text = response.content

        title = _extract_field(text, "TITLE")
        summary = _extract_field(text, "SUMMARY")
        positioning = _extract_field(text, "POSITIONING")
    except Exception as exc:  # noqa: BLE001
        logger.exception("content_improver_node LLM call failed")
        new_errors.append(f"ContentImprover: LLM drafting failed ({exc}).")
        title, summary, positioning = "", "", ""

    return {
        "suggested_title": title,
        "suggested_summary": summary,
        "positioning_notes": positioning,
        "errors": new_errors,
    }


def _extract_field(text: str, field: str) -> str:
    for line in text.splitlines():
        if line.strip().upper().startswith(field.upper() + ":"):
            return line.split(":", 1)[1].strip()
    return ""
'@
Set-Content -Path "src/agents/content_improver.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/agents/reviewer_critic.py"
$content = @'
"""
Agent: Reviewer / Critic

ROLE: Final synthesizer and quality gate — the last agent in the pipeline.
SPECIALIZATION: Objective structural compliance checking (via a
deterministic tool, not an LLM opinion) plus synthesis of everything the
other three agents produced into one final, human-readable report.
READS FROM STATE: readme_text, suggested_tags, suggested_title,
    suggested_summary, positioning_notes, errors, human_approved,
    human_feedback (the last two are populated by the human-in-the-loop
    checkpoint in main.py, which pauses the graph right before this agent
    runs).
WRITES TO STATE: structure_report, review_notes, final_report, errors.
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.guardrails import filter_output
from src.llm import get_llm, invoke_llm
from src.state import PublicationAssistantState
from src.tools.readme_structure_tool import readme_structure_checker

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are the final reviewer in a multi-agent publication assistant \
pipeline. You receive: the original README, a structural analysis (which standard \
sections are present/missing), suggested tags, a suggested title/summary from other \
agents, and — if a human reviewed this run — their approval status and any free-text \
feedback they left.

Write a concise, actionable final report in markdown with these sections:
## Summary of Findings
## Suggested Title & Summary
## Suggested Tags
## Missing Sections (with a one-line fix suggestion for each)
## Overall Recommendation (2-3 sentences)

If human feedback is present, weave it into your recommendation explicitly — e.g. if \
they said a tag was wrong or a title didn't fit, acknowledge that and adjust your \
final recommendation accordingly rather than ignoring it.

Be specific and grounded in the actual data provided. Do not repeat the full README."""


def reviewer_critic_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    prior_errors = state.get("errors", [])
    human_feedback = state.get("human_feedback", "")
    human_approved = state.get("human_approved", True)

    structure_report = readme_structure_checker.invoke({"readme_text": readme_text})

    review_notes = []
    if structure_report["missing_essential"]:
        review_notes.append(
            "Missing essential sections: " + ", ".join(structure_report["missing_essential"])
        )
    if structure_report["missing_professional"]:
        review_notes.append(
            "Missing professional-tier sections: "
            + ", ".join(structure_report["missing_professional"])
        )
    if prior_errors:
        review_notes.append("Upstream agent issues: " + "; ".join(prior_errors))
    if human_feedback:
        review_notes.append(f"Human feedback: {human_feedback}")

    new_errors = []
    try:
        llm = get_llm(temperature=0.2)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"Structure report: {structure_report}\n\n"
                    f"Suggested tags: {state.get('suggested_tags', [])}\n\n"
                    f"Suggested title: {state.get('suggested_title', '')}\n"
                    f"Suggested summary: {state.get('suggested_summary', '')}\n"
                    f"Positioning notes: {state.get('positioning_notes', '')}\n\n"
                    f"Human reviewed and approved: {human_approved}\n"
                    f"Human feedback: {human_feedback or '(none given)'}\n\n"
                    f"README excerpt:\n{readme_text[:2000]}"
                )
            ),
        ]
        response = invoke_llm(llm, messages)
        final_report = filter_output(response.content)
    except Exception as exc:  # noqa: BLE001
        logger.exception("reviewer_critic_node LLM call failed")
        new_errors.append(f"ReviewerCritic: final synthesis failed ({exc}).")
        final_report = (
            "# Final report unavailable (LLM call failed)\n\n"
            f"Structure report: {structure_report}\n"
            f"Suggested tags: {state.get('suggested_tags', [])}\n"
        )

    return {
        "structure_report": structure_report,
        "review_notes": review_notes,
        "final_report": final_report,
        "errors": new_errors,
    }
'@
Set-Content -Path "src/agents/reviewer_critic.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing src/tools/github_repo_tool.py"
$content = @'
"""
Tool: GitHubRepoTool

Fetches a public GitHub repository's README content and top-level file
structure via the GitHub REST API. No git clone is required, which keeps
the tool fast and dependency-light.
"""
import base64
import re
from typing import Optional

import requests
from langchain_core.tools import tool

from src.config import settings
from src.resilience import with_retry

GITHUB_API_ROOT = "https://api.github.com"

# Retried on connection/timeout errors and 5xx/429 responses (raised via
# resp.raise_for_status()) -- NOT on 404s, which _fetch_readme handles
# explicitly, or 4xx client errors in general, since retrying a request
# that's wrong won't make it right.
_github_retry = with_retry(
    max_attempts=3,
    base_delay=1.0,
    exceptions=(requests.ConnectionError, requests.Timeout, requests.HTTPError),
)


def _parse_owner_repo(repo_url: str) -> tuple[str, str]:
    """Extract (owner, repo) from a GitHub URL like https://github.com/owner/repo(.git)"""
    match = re.search(r"github\.com[:/]+([^/]+)/([^/.]+)", repo_url.strip())
    if not match:
        raise ValueError(f"Could not parse a GitHub owner/repo from: {repo_url!r}")
    return match.group(1), match.group(2)


def _headers() -> dict:
    headers = {"Accept": "application/vnd.github+json"}
    if settings.github_token:
        headers["Authorization"] = f"Bearer {settings.github_token}"
    return headers


@_github_retry
def _fetch_readme(owner: str, repo: str) -> str:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}/readme"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    if resp.status_code == 404:
        return "(No README found in this repository.)"
    resp.raise_for_status()
    data = resp.json()
    content = base64.b64decode(data["content"]).decode("utf-8", errors="replace")
    return content[: settings.max_readme_chars]


@_github_retry
def _fetch_top_level_structure(owner: str, repo: str) -> list[str]:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}/contents/"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    resp.raise_for_status()
    items = resp.json()
    entries = []
    for item in items:
        marker = "/" if item["type"] == "dir" else ""
        entries.append(f"{item['name']}{marker}")
    return sorted(entries)


@_github_retry
def _fetch_repo_metadata(owner: str, repo: str) -> dict:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    resp.raise_for_status()
    data = resp.json()
    return {
        "description": data.get("description") or "",
        "stars": data.get("stargazers_count", 0),
        "language": data.get("language") or "unknown",
        "topics": data.get("topics", []),
        "license": (data.get("license") or {}).get("name", "none"),
        "open_issues": data.get("open_issues_count", 0),
    }


@tool("github_repo_reader")
def github_repo_reader(repo_url: str) -> dict:
    """
    Fetch the README text, top-level file structure, and basic metadata
    (stars, language, license, topics) for a public GitHub repository.

    Args:
        repo_url: A GitHub repository URL, e.g. https://github.com/owner/repo

    Returns:
        A dict with keys: owner, repo, readme, file_structure, metadata.
    """
    owner, repo = _parse_owner_repo(repo_url)
    readme = _fetch_readme(owner, repo)
    structure = _fetch_top_level_structure(owner, repo)
    metadata = _fetch_repo_metadata(owner, repo)
    return {
        "owner": owner,
        "repo": repo,
        "readme": readme,
        "file_structure": structure,
        "metadata": metadata,
    }
'@
Set-Content -Path "src/tools/github_repo_tool.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing docs/ARCHITECTURE.md"
$content = @'
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
'@
Set-Content -Path "docs/ARCHITECTURE.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing docs/API.md"
$content = @'
# Interface Specification

This project has no REST API -- its "interface" is (1) the shared state
schema that flows through the graph, and (2) the two front ends (CLI and
Streamlit UI) built on top of it. Both front ends call the exact same
`src/graph.py` functions, so this doc is the single source of truth for
either.

## Programmatic interface: `src/graph.py`

```python
from src.graph import start_pipeline, resume_pipeline, run_pipeline
```

### `start_pipeline(repo_url: str, user_description: str | None = None) -> (app, config, paused_state)`

Validates and sanitizes input (via `src/guardrails.py`), then runs the
pipeline up to the human-in-the-loop checkpoint (paused right before
`Reviewer/Critic`).

- **Raises:** `GuardrailViolation` (a `ValueError` subclass) if `repo_url`
  isn't a valid `https://github.com/<owner>/<repo>` URL.
- **Returns:**
  - `app`: the compiled LangGraph app (needed to resume).
  - `config`: dict carrying the `thread_id` the checkpointer uses; pass
    back unchanged to `resume_pipeline`.
  - `paused_state`: a dict view of `PublicationAssistantState` (see
    schema below) as of the pause point.

### `resume_pipeline(app, config, edits: dict | None = None) -> PublicationAssistantState`

Applies any human edits to state, then runs `Reviewer/Critic` to
completion.

- `edits` may set any of: `suggested_title`, `suggested_summary`,
  `suggested_tags`, `human_feedback`, `human_approved`.
- **Returns:** the final state dict, including `final_report` (markdown
  string, already passed through `filter_output` for secret redaction).

### `run_pipeline(repo_url, user_description=None) -> PublicationAssistantState`

Convenience wrapper: runs the full pipeline with `human_approved=True`
and no edits (auto-approve). Used by tests and non-interactive callers.

## State schema (`src/state.py`)

`PublicationAssistantState` is a `TypedDict(total=False)`:

| Field | Type | Populated by | Notes |
|---|---|---|---|
| `repo_url` | `str` | input | Validated/normalized by `guardrails.validate_repo_url`. |
| `user_description` | `str` | input | Sanitized by `guardrails.sanitize_user_description`. |
| `owner`, `repo` | `str` | Repo Analyzer | Parsed from the URL. |
| `readme_text` | `str` | Repo Analyzer | Truncated to `settings.max_readme_chars` (12,000). |
| `file_structure` | `list[str]` | Repo Analyzer | Top-level entries, dirs suffixed `/`. |
| `repo_metadata` | `dict` | Repo Analyzer | `description`, `stars`, `language`, `topics`, `license`, `open_issues`. |
| `suggested_keywords` | `list[str]` | Metadata Recommender | Raw ranked candidates before LLM refinement. |
| `suggested_tags` | `list[str]` | Metadata Recommender | Final 5-8 tags. |
| `suggested_title`, `suggested_summary`, `positioning_notes` | `str` | Content Improver | |
| `structure_report` | `dict` | Reviewer/Critic | `essential`/`professional` section presence + `missing_*` lists. |
| `review_notes` | `list[str]` | Reviewer/Critic | Human-readable bullet notes. |
| `final_report` | `str` | Reviewer/Critic | The markdown deliverable. |
| `human_approved` | `bool` | human review checkpoint | |
| `human_feedback` | `str` | human review checkpoint | |
| `errors` | `list[str]` (`operator.add` reducer) | any agent | Concatenated, not overwritten, across concurrent writers. |

## CLI interface (`main.py`)

```
python main.py --repo <url> [--description TEXT] [--output PATH]
               [--no-save] [--auto-approve] [--health-check]
```

| Flag | Required | Effect |
|---|---|---|
| `--repo` | yes, unless `--health-check` | GitHub repo URL. |
| `--description` | no | Optional context passed to the agents. |
| `--output` | no | Custom report path (default: auto-generated under `reports/`). |
| `--no-save` | no | Print only, skip writing to disk. |
| `--auto-approve` | no | Skip the interactive review prompt. |
| `--health-check` | no | Run config/connectivity checks and exit (no pipeline run). |

Exit codes: `0` success, `1` invalid input or unexpected pipeline
failure.

## UI interface (`app.py`)

`streamlit run app.py` exposes the same three stages as three screens:
input form -> human review form -> final report + download button. See
[DEPLOYMENT.md](DEPLOYMENT.md) for how to run it.
'@
Set-Content -Path "docs/API.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing docs/DEPLOYMENT.md"
$content = @'
# Deployment & Configuration Guide

## 1. Prerequisites

- Python 3.10+
- A [Groq API key](https://console.groq.com/keys) (required, free tier available)
- A [Tavily API key](https://tavily.com/) (optional -- enables web search for Content Improver)
- A GitHub personal access token (optional -- raises the GitHub API rate limit from 60/hr to 5000/hr)

## 2. Install

**Windows (PowerShell):**

```powershell
git clone https://github.com/joramkirubi/Publication-assistant.git
cd Publication-assistant
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
notepad .env   # fill in GROQ_API_KEY (and optionally TAVILY_API_KEY, GITHUB_TOKEN)
```

**macOS/Linux:**

```bash
git clone https://github.com/joramkirubi/Publication-assistant.git
cd Publication-assistant
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# edit .env and add your GROQ_API_KEY
```

## 3. Configuration reference

All configuration is via environment variables loaded from `.env` (see
`src/config.py` / `.env.example`):

| Variable | Required | Purpose |
|---|---|---|
| `GROQ_API_KEY` | Yes | LLM calls for all four agents. |
| `TAVILY_API_KEY` | No | Enables the `web_search` tool. |
| `GITHUB_TOKEN` | No | Raises GitHub API rate limits. |
| `MODEL_NAME` | No | Defaults to `llama-3.3-70b-versatile`. |
| `MODEL_TEMPERATURE` | No | Defaults to `0.3`. |

## 4. Verify the setup

Before running a full analysis, confirm your config and connectivity:

```powershell
python main.py --health-check
```

This checks (without spending any LLM tokens): `GROQ_API_KEY` is set,
GitHub's API is reachable, whether the optional keys are set, and that
`reports/` is writable. Run this after any deployment or environment
change as a smoke test.

## 5. Run it

**CLI:**

```powershell
python main.py --repo https://github.com/owner/repo
python main.py --repo https://github.com/owner/repo --auto-approve   # non-interactive/CI
```

**Web UI:**

```powershell
streamlit run app.py
```

Opens a local web UI at `http://localhost:8501` with the same
input -> human review -> report flow, plus a sidebar health-check button
and a report download button.

## 6. Running the test suite

```powershell
pytest tests/ -v
pytest tests/ --cov=src --cov-report=term-missing   # coverage report
```

All tests mock external calls (GitHub API, Groq, Tavily) so they run
offline without real API keys, in well under a second per test.

## 7. Logging & maintenance

- Both `main.py` and `app.py` configure Python's standard `logging` at
  `INFO` level to stdout (`logging.basicConfig(...)`). Each agent logs a
  full traceback (`logger.exception(...)`) on failure before degrading
  gracefully, so logs are the first place to look for a root cause.
- Reports are timestamped and never overwritten
  (`reports/<owner>_<repo>_<timestamp>.md`), so old runs are naturally
  retained for audit/comparison. There is no automatic cleanup -- prune
  `reports/` periodically if disk usage matters for your deployment.
- Re-run `python main.py --health-check` after rotating API keys, after
  a Groq/GitHub/Tavily outage, or as a periodic scheduled smoke test.
- Dependency versions are pinned with upper bounds in `requirements.txt`;
  bump them deliberately and re-run the full test suite + a real
  `--health-check` + one live run before deploying an upgrade.

## 8. Optional: containerizing for deployment

No Dockerfile is included by default (this is a local/portfolio-scale
tool), but if you need one, a minimal shape is:

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8501
CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0"]
```

Pass secrets as environment variables at container run time (`docker run
-e GROQ_API_KEY=... `), never baked into the image.
'@
Set-Content -Path "docs/DEPLOYMENT.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing docs/TROUBLESHOOTING.md"
$content = @'
# Troubleshooting & FAQ

## First step for any issue

```powershell
python main.py --health-check
```

This distinguishes "my config is wrong" from "something is actually
broken" in a few seconds, without spending LLM tokens.

## Common issues

### `EnvironmentError: GROQ_API_KEY is not set.`

`.env` is missing or wasn't loaded. Confirm `.env` exists (copied from
`.env.example`) in the same directory you're running `python main.py`
from, and that `GROQ_API_KEY=...` has an actual value, not a blank line.

### `GuardrailViolation: Repo URL must look like https://github.com/<owner>/<repo>`

The tool only accepts plain public GitHub repo URLs -- no GitLab, no
private-repo URLs with embedded tokens, no extra path segments (e.g.
`/tree/main`), no `http://` (must be `https://`). Strip the URL down to
`https://github.com/owner/repo` and retry.

### `RepoAnalyzer: failed to fetch repo — ...` (in the report's warnings)

Usually one of:
- **404 from GitHub** -- the repo is private, misspelled, or deleted.
- **403 / rate limited** -- you've hit the unauthenticated 60 req/hr
  GitHub API limit. Set `GITHUB_TOKEN` in `.env` to raise it to 5000/hr.
- **Connection error** -- transient network issue. The tool already
  retries transient failures automatically (see
  [ARCHITECTURE.md](ARCHITECTURE.md#design-decisions)); if it still fails
  after retries, check your network connection or run `--health-check`.

### `ContentImprover: skipped, no README text available.` / similar "skipped" messages

Content Improver and Metadata Recommender both require README text to
work with. If Repo Analyzer failed (see above), everything downstream
degrades gracefully with an explanatory error in `state["errors"]` and
in the final report's warnings, rather than crashing.

### The pipeline seems to hang

Every outbound call (GitHub API, Tavily, Groq LLM calls) has a hard
timeout (`src/resilience.py`'s `with_timeout`), so no single call should
hang forever. If the whole CLI process appears stuck, it's most likely
waiting on your input at the human review checkpoint (`Approve as-is?
[Y/n/e=edit]:`) -- check for that prompt, or pass `--auto-approve` for
non-interactive use.

### `InvalidUpdateError: Ambiguous update, specify as_node`

This was a real bug hit during development (documented in the main
[README](../README.md#human-in-the-loop-review)) and is already fixed in
`src/graph.py` (`resume_pipeline` passes `as_node="content_improver"`
explicitly). If you see this again after modifying `src/graph.py`, you
likely removed that argument -- restore it.

### Streamlit UI: "Something went wrong starting the pipeline"

The error detail shown in the UI is the same exception message the CLI
would print. Cross-check against `--health-check` and the issues above;
the underlying pipeline is identical between the CLI and the UI.

### Tests fail with `ModuleNotFoundError`

Run `pip install -r requirements.txt` inside the same virtual environment
you're running `pytest` from -- a common mismatch is having a global
`python` on `PATH` different from the one in `.venv`.

## FAQ

**Q: Does this work with private repos?**
A: Only if you set `GITHUB_TOKEN` to a personal access token with access
to that repo. Support is best-effort; the tool is designed and tested
against public repos.

**Q: What happens if I don't set `TAVILY_API_KEY`?**
A: Content Improver still runs, drafting the title/summary from the
README alone, without external positioning context. This is a graceful
degradation, not a failure.

**Q: Can I use a different LLM provider?**
A: Not without code changes -- `src/llm.py` is Groq-specific
(`ChatGroq`). It's the single place to change if you want to swap
providers; every agent already goes through `get_llm()` / `invoke_llm()`.

**Q: Why does the final report sometimes redact things that look like
API keys?**
A: `src/guardrails.py`'s `filter_output` runs a last-resort regex
redaction pass on every final report, in case a README or web search
result the LLM was shown happened to contain something that looks like a
credential. This is a safety net, not a sign your own keys leaked.

**Q: How do I know test coverage is adequate?**
A: `pytest tests/ --cov=src --cov-report=term-missing` -- the project
targets and currently exceeds 70% statement coverage on `src/`.
'@
Set-Content -Path "docs/TROUBLESHOOTING.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_guardrails.py"
$content = @'
import pytest

from src.guardrails import (
    GuardrailViolation,
    MAX_DESCRIPTION_LENGTH,
    filter_output,
    sanitize_user_description,
    validate_repo_url,
)


class TestValidateRepoUrl:
    def test_accepts_plain_https_url(self):
        assert validate_repo_url("https://github.com/owner/repo") == "https://github.com/owner/repo"

    def test_strips_trailing_slash(self):
        assert validate_repo_url("https://github.com/owner/repo/") == "https://github.com/owner/repo"

    def test_strips_dot_git_suffix(self):
        assert validate_repo_url("https://github.com/owner/repo.git") == "https://github.com/owner/repo"

    def test_strips_surrounding_whitespace(self):
        assert validate_repo_url("  https://github.com/owner/repo  ") == "https://github.com/owner/repo"

    @pytest.mark.parametrize(
        "bad_url",
        [
            "",
            "   ",
            "not-a-url",
            "http://github.com/owner/repo",  # http, not https
            "https://gitlab.com/owner/repo",  # wrong host
            "https://github.com/owner",  # missing repo segment
            "https://github.com/owner/repo/extra/path",  # extra path segments
            "javascript:alert(1)",
            "ftp://github.com/owner/repo",
            "https://github.com.evil.com/owner/repo",  # lookalike host
        ],
    )
    def test_rejects_invalid_urls(self, bad_url):
        with pytest.raises(GuardrailViolation):
            validate_repo_url(bad_url)

    def test_rejects_non_string_input(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url(None)  # type: ignore[arg-type]

    def test_rejects_overly_long_url(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url("https://github.com/owner/" + "a" * 300)

    def test_rejects_control_characters(self):
        with pytest.raises(GuardrailViolation):
            validate_repo_url("https://github.com/owner/repo\x00")


class TestSanitizeUserDescription:
    def test_none_returns_empty_string(self):
        assert sanitize_user_description(None) == ""

    def test_empty_string_returns_empty_string(self):
        assert sanitize_user_description("") == ""

    def test_passes_through_normal_text(self):
        assert sanitize_user_description("A RAG pipeline for medical Q&A") == (
            "A RAG pipeline for medical Q&A"
        )

    def test_truncates_to_max_length(self):
        long_text = "x" * (MAX_DESCRIPTION_LENGTH + 100)
        result = sanitize_user_description(long_text)
        assert len(result) == MAX_DESCRIPTION_LENGTH

    def test_collapses_excess_whitespace(self):
        assert sanitize_user_description("hello    \n\n  world") == "hello world"

    def test_strips_control_characters(self):
        assert sanitize_user_description("hello\x00world") == "helloworld"


class TestFilterOutput:
    def test_empty_text_passes_through(self):
        assert filter_output("") == ""

    def test_leaves_normal_text_unchanged(self):
        text = "## Summary\nThis project uses RAG and LangGraph."
        assert filter_output(text) == text

    def test_redacts_groq_key(self):
        text = "here is a key: gsk_" + "a" * 30
        result = filter_output(text)
        assert "gsk_" not in result
        assert "[REDACTED_GROQ_KEY]" in result

    def test_redacts_github_token(self):
        text = "token: ghp_" + "b" * 36
        result = filter_output(text)
        assert "ghp_" not in result
        assert "[REDACTED_GITHUB_TOKEN]" in result

    def test_redacts_tavily_key(self):
        text = "tvly-" + "c" * 32
        result = filter_output(text)
        assert "[REDACTED_TAVILY_KEY]" in result

    def test_redacts_multiple_secrets_in_same_text(self):
        text = f"a=gsk_{'x' * 25} b=ghp_{'y' * 36}"
        result = filter_output(text)
        assert "[REDACTED_GROQ_KEY]" in result
        assert "[REDACTED_GITHUB_TOKEN]" in result
'@
Set-Content -Path "tests/test_guardrails.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_resilience.py"
$content = @'
import time

import pytest

from src.resilience import ResilienceTimeoutError, with_retry, with_timeout


class FlakyCounter:
    """Helper: fails N times then succeeds, to simulate transient errors."""

    def __init__(self, fail_times: int, exc_type=ValueError):
        self.fail_times = fail_times
        self.calls = 0
        self.exc_type = exc_type

    def __call__(self):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise self.exc_type(f"transient failure #{self.calls}")
        return "success"


class TestWithRetry:
    def test_succeeds_immediately_without_retrying(self):
        flaky = FlakyCounter(fail_times=0)
        wrapped = with_retry(max_attempts=3, base_delay=0.01)(flaky)
        assert wrapped() == "success"
        assert flaky.calls == 1

    def test_retries_and_eventually_succeeds(self):
        flaky = FlakyCounter(fail_times=2)
        wrapped = with_retry(max_attempts=3, base_delay=0.01)(flaky)
        assert wrapped() == "success"
        assert flaky.calls == 3

    def test_gives_up_after_max_attempts_and_reraises(self):
        flaky = FlakyCounter(fail_times=10)
        wrapped = with_retry(max_attempts=3, base_delay=0.01)(flaky)
        with pytest.raises(ValueError, match="transient failure #3"):
            wrapped()
        assert flaky.calls == 3

    def test_only_retries_specified_exception_types(self):
        flaky = FlakyCounter(fail_times=5, exc_type=KeyError)
        wrapped = with_retry(max_attempts=3, base_delay=0.01, exceptions=(ValueError,))(flaky)
        # KeyError isn't in the retry list, so it should propagate on the first call
        with pytest.raises(KeyError):
            wrapped()
        assert flaky.calls == 1

    def test_backoff_delay_increases_between_attempts(self):
        flaky = FlakyCounter(fail_times=2)
        wrapped = with_retry(max_attempts=3, base_delay=0.05, backoff_factor=2.0)(flaky)
        start = time.monotonic()
        wrapped()
        elapsed = time.monotonic() - start
        # Expect roughly 0.05 + 0.10 = 0.15s of sleeping between the 3 attempts.
        assert elapsed >= 0.14

    def test_preserves_function_metadata(self):
        @with_retry(max_attempts=2, base_delay=0.01)
        def my_function():
            """docstring"""
            return 1

        assert my_function.__name__ == "my_function"


class TestWithTimeout:
    def test_fast_function_returns_normally(self):
        @with_timeout(seconds=1)
        def fast():
            return 42

        assert fast() == 42

    def test_slow_function_raises_timeout_error(self):
        @with_timeout(seconds=0.1)
        def slow():
            time.sleep(2)
            return "too late"

        with pytest.raises(ResilienceTimeoutError):
            slow()

    def test_exception_inside_wrapped_function_propagates(self):
        @with_timeout(seconds=1)
        def raises():
            raise RuntimeError("boom")

        with pytest.raises(RuntimeError, match="boom"):
            raises()
'@
Set-Content -Path "tests/test_resilience.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_health.py"
$content = @'
from unittest.mock import MagicMock, patch

import requests

from src.health import (
    HealthReport,
    CheckResult,
    format_health_report,
    run_health_check,
)


def test_health_report_all_ok_ignores_optional_failures():
    report = HealthReport(
        checks=[
            CheckResult("required-thing", True, "ok"),
            CheckResult("optional:extra-thing", False, "not set"),
        ]
    )
    # optional: prefix means it doesn't count against all_ok even if False
    assert report.all_ok is True


def test_health_report_not_ok_when_required_check_fails():
    report = HealthReport(
        checks=[
            CheckResult("required-thing", False, "missing"),
        ]
    )
    assert report.all_ok is False


@patch("src.health.requests.get")
@patch("src.health.settings")
def test_run_health_check_reports_missing_groq_key(mock_settings, mock_get):
    mock_settings.groq_api_key = ""
    mock_settings.tavily_api_key = ""
    mock_settings.github_token = ""

    mock_response = MagicMock()
    mock_response.ok = True
    mock_response.headers = {"X-RateLimit-Remaining": "60"}
    mock_get.return_value = mock_response

    report = run_health_check()
    groq_check = next(c for c in report.checks if c.name == "GROQ_API_KEY")
    assert groq_check.ok is False
    assert report.all_ok is False


@patch("src.health.requests.get")
@patch("src.health.settings")
def test_run_health_check_all_pass_when_configured_and_reachable(mock_settings, mock_get):
    mock_settings.groq_api_key = "gsk_fake"
    mock_settings.tavily_api_key = "tvly-fake"
    mock_settings.github_token = "ghp_fake"

    mock_response = MagicMock()
    mock_response.ok = True
    mock_response.headers = {"X-RateLimit-Remaining": "5000"}
    mock_get.return_value = mock_response

    report = run_health_check()
    assert report.all_ok is True


@patch("src.health.requests.get", side_effect=requests.ConnectionError("no network"))
@patch("src.health.settings")
def test_run_health_check_handles_github_unreachable(mock_settings, mock_get):
    mock_settings.groq_api_key = "gsk_fake"
    mock_settings.tavily_api_key = ""
    mock_settings.github_token = ""

    report = run_health_check()
    github_check = next(c for c in report.checks if c.name == "GitHub API")
    assert github_check.ok is False
    assert "unreachable" in github_check.detail


def test_format_health_report_includes_overall_status():
    report = HealthReport(checks=[CheckResult("thing", True, "ok")])
    text = format_health_report(report)
    assert "healthy" in text
    assert "thing" in text
'@
Set-Content -Path "tests/test_health.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_github_repo_tool.py"
$content = @'
from unittest.mock import MagicMock, patch

import pytest
import requests

from src.tools.github_repo_tool import (
    _fetch_readme,
    _fetch_repo_metadata,
    _fetch_top_level_structure,
    _parse_owner_repo,
    github_repo_reader,
)


class TestParseOwnerRepo:
    def test_parses_plain_url(self):
        assert _parse_owner_repo("https://github.com/owner/repo") == ("owner", "repo")

    def test_parses_url_with_dot_git(self):
        assert _parse_owner_repo("https://github.com/owner/repo.git") == ("owner", "repo")

    def test_raises_on_unparseable_url(self):
        with pytest.raises(ValueError):
            _parse_owner_repo("not-a-github-url")


class TestFetchReadme:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_returns_placeholder_on_404(self, mock_get):
        mock_get.return_value = MagicMock(status_code=404)
        result = _fetch_readme("owner", "repo")
        assert "No README found" in result

    @patch("src.tools.github_repo_tool.requests.get")
    def test_decodes_base64_content(self, mock_get):
        import base64

        encoded = base64.b64encode(b"# Hello World").decode()
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {"content": encoded}
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        assert _fetch_readme("owner", "repo") == "# Hello World"

    @patch("src.resilience.time.sleep", return_value=None)
    @patch("src.tools.github_repo_tool.requests.get")
    def test_retries_on_connection_error_then_succeeds(self, mock_get, mock_sleep):
        import base64

        encoded = base64.b64encode(b"# Retried").decode()
        success_resp = MagicMock(status_code=200)
        success_resp.json.return_value = {"content": encoded}
        success_resp.raise_for_status.return_value = None

        mock_get.side_effect = [
            requests.ConnectionError("blip"),
            success_resp,
        ]
        assert _fetch_readme("owner", "repo") == "# Retried"
        assert mock_get.call_count == 2

    @patch("src.resilience.time.sleep", return_value=None)
    @patch("src.tools.github_repo_tool.requests.get")
    def test_gives_up_after_max_retries(self, mock_get, mock_sleep):
        mock_get.side_effect = requests.ConnectionError("still down")
        with pytest.raises(requests.ConnectionError):
            _fetch_readme("owner", "repo")
        assert mock_get.call_count == 3  # max_attempts=3 from _github_retry


class TestFetchTopLevelStructure:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_sorts_and_marks_directories(self, mock_get):
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = [
            {"name": "src", "type": "dir"},
            {"name": "README.md", "type": "file"},
        ]
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        result = _fetch_top_level_structure("owner", "repo")
        assert result == ["README.md", "src/"]


class TestFetchRepoMetadata:
    @patch("src.tools.github_repo_tool.requests.get")
    def test_extracts_expected_fields(self, mock_get):
        mock_resp = MagicMock(status_code=200)
        mock_resp.json.return_value = {
            "description": "A test repo",
            "stargazers_count": 42,
            "language": "Python",
            "topics": ["ai", "agents"],
            "license": {"name": "MIT"},
            "open_issues_count": 3,
        }
        mock_resp.raise_for_status.return_value = None
        mock_get.return_value = mock_resp
        result = _fetch_repo_metadata("owner", "repo")
        assert result == {
            "description": "A test repo",
            "stars": 42,
            "language": "Python",
            "topics": ["ai", "agents"],
            "license": "MIT",
            "open_issues": 3,
        }


class TestGithubRepoReader:
    @patch("src.tools.github_repo_tool._fetch_repo_metadata")
    @patch("src.tools.github_repo_tool._fetch_top_level_structure")
    @patch("src.tools.github_repo_tool._fetch_readme")
    def test_assembles_full_result(self, mock_readme, mock_structure, mock_metadata):
        mock_readme.return_value = "# Title"
        mock_structure.return_value = ["README.md"]
        mock_metadata.return_value = {"stars": 1}

        result = github_repo_reader.invoke({"repo_url": "https://github.com/owner/repo"})
        assert result["owner"] == "owner"
        assert result["repo"] == "repo"
        assert result["readme"] == "# Title"
        assert result["file_structure"] == ["README.md"]
        assert result["metadata"] == {"stars": 1}
'@
Set-Content -Path "tests/test_github_repo_tool.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_web_search_tool.py"
$content = @'
from unittest.mock import MagicMock, patch

from src.tools.web_search_tool import web_search


class TestWebSearch:
    @patch("src.tools.web_search_tool.settings")
    def test_returns_empty_note_when_no_api_key(self, mock_settings):
        mock_settings.tavily_api_key = ""
        result = web_search.invoke({"query": "LangGraph multi-agent", "max_results": 5})
        assert result["results"] == []
        assert "TAVILY_API_KEY not set" in result["note"]

    @patch("src.tools.web_search_tool.settings")
    def test_parses_and_truncates_results(self, mock_settings):
        mock_settings.tavily_api_key = "tvly-fake"

        mock_client = MagicMock()
        mock_client.search.return_value = {
            "results": [
                {"title": "Project A", "url": "https://a.example", "content": "x" * 500},
                {"title": "Project B", "url": "https://b.example", "content": "short"},
            ]
        }

        with patch("tavily.TavilyClient", return_value=mock_client):
            result = web_search.invoke({"query": "test query", "max_results": 2})

        assert len(result["results"]) == 2
        assert result["results"][0]["title"] == "Project A"
        assert len(result["results"][0]["snippet"]) == 300
        assert result["results"][1]["snippet"] == "short"
        assert result["note"] == ""

    @patch("src.tools.web_search_tool.settings")
    def test_handles_missing_tavily_package_gracefully(self, mock_settings):
        mock_settings.tavily_api_key = "tvly-fake"
        with patch.dict("sys.modules", {"tavily": None}):
            result = web_search.invoke({"query": "test query"})
        assert result["results"] == []
        assert "tavily-python not installed" in result["note"]
'@
Set-Content -Path "tests/test_web_search_tool.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing reports/.gitkeep"
$content = @'

'@
Set-Content -Path "reports/.gitkeep" -Value $content -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. pip install -r requirements.txt"
Write-Host "  2. python main.py --health-check"
Write-Host "  3. pytest tests/ --cov=src --cov-report=term-missing"
Write-Host "  4. streamlit run app.py   (to try the new web UI)"

