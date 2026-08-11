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

## 8. Containerized deployment

A `Dockerfile`, `docker-compose.yml`, and `.dockerignore` are included at
the repo root. Secrets are never baked into the image -- they're passed
at run time via `.env` (Compose) or `-e` flags (plain `docker run`).

```powershell
# One-command deployment, reads secrets from .env
docker compose up

# Equivalent plain docker commands
docker build -t publication-assistant .
docker run -e GROQ_API_KEY=... -e TAVILY_API_KEY=... -p 8501:8501 publication-assistant
```

The image runs the Streamlit UI by default (`CMD` in the `Dockerfile`)
and includes a container-level `HEALTHCHECK` that calls
`python main.py --health-check` -- this confirms `GROQ_API_KEY` is set
and GitHub is reachable, not just that the process is alive, which is
what Streamlit's own liveness check alone would tell you.

## 9. Continuous integration

`.github/workflows/tests.yml` runs the full test suite (with a 70%
coverage floor enforced via `--cov-fail-under=70`) on every push and pull
request to `main`, across Python 3.10, 3.11, and 3.12. A failing test or
a coverage regression blocks the merge rather than being caught after
deployment.

## 10. Streamlit-specific configuration

`.streamlit/config.toml` sets headless mode, binds to `0.0.0.0:8501` (so
it's reachable from outside a container), disables Streamlit's own usage
telemetry, and enables XSRF protection. This file is read automatically
by `streamlit run app.py` with no additional flags needed.