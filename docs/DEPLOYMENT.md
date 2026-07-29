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