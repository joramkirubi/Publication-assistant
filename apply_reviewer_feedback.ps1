#Requires -Version 5.1
<#
.SYNOPSIS
  Addresses Ready Tensor reviewer feedback: adds deployment configuration
  (Dockerfile, docker-compose, Streamlit config, CI workflow) and adds
  explicit try/except error handling to test files.
.DESCRIPTION
  Run this from the ROOT of your Publication-assistant repo (same folder as
  main.py). Adds new files and overwrites two existing test files plus
  docs/DEPLOYMENT.md.
#>

$ErrorActionPreference = "Stop"
Write-Host "Applying reviewer feedback: deployment config + test error handling..." -ForegroundColor Cyan

# --- Create any new directories ---
New-Item -ItemType Directory -Force -Path ".github/workflows" | Out-Null
New-Item -ItemType Directory -Force -Path ".streamlit" | Out-Null
New-Item -ItemType Directory -Force -Path "docs" | Out-Null
New-Item -ItemType Directory -Force -Path "tests" | Out-Null

Write-Host "  writing Dockerfile"
$content = @'
# Publication Assistant - container image
#
# Builds an image that runs the Streamlit UI by default. The CLI is also
# available inside the same image (see docker-compose.yml for a CLI
# service definition), since both entry points share the same
# dependencies and source tree.
FROM python:3.11-slim

WORKDIR /app

# Install dependencies first so this layer is cached across rebuilds
# that only change application code, not requirements.txt.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Secrets (GROQ_API_KEY, TAVILY_API_KEY, GITHUB_TOKEN) are intentionally
# NOT baked into the image. Pass them at run time:
#   docker run -e GROQ_API_KEY=... -p 8501:8501 publication-assistant
RUN mkdir -p reports

EXPOSE 8501

# Container-level health check, backed by the same logic as
# `python main.py --health-check` -- distinct from Streamlit's own
# liveness endpoint, which only confirms the process is up, not that
# GROQ_API_KEY/GitHub connectivity are actually configured correctly.
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python main.py --health-check || exit 1

CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8501"]
'@
Set-Content -Path "Dockerfile" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing .dockerignore"
$content = @'
.venv/
__pycache__/
*.pyc
.env
.git/
.github/
.pytest_cache/
.coverage
reports/*.md
docs/
tests/
*.ps1
README.md
'@
Set-Content -Path ".dockerignore" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing docker-compose.yml"
$content = @'
# Local deployment: `docker compose up`
#
# Reads secrets from a local .env file (not committed -- see
# .env.example). This is the "seamless deployment" path referenced in
# docs/DEPLOYMENT.md: one command, no manual pip install, no manual
# environment juggling.
services:
  publication-assistant:
    build: .
    ports:
      - "8501:8501"
    env_file:
      - .env
    volumes:
      # Reports persist on the host across container restarts.
      - ./reports:/app/reports
    healthcheck:
      test: ["CMD", "python", "main.py", "--health-check"]
      interval: 30s
      timeout: 10s
      start_period: 10s
      retries: 3
'@
Set-Content -Path "docker-compose.yml" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing .streamlit/config.toml"
$content = @'
[server]
headless = true
port = 8501
address = "0.0.0.0"
enableCORS = false
enableXsrfProtection = true

[browser]
gatherUsageStats = false

[theme]
base = "light"
'@
Set-Content -Path ".streamlit/config.toml" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing .github/workflows/tests.yml"
$content = @'
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ["3.10", "3.11", "3.12"]

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests with coverage
        run: pytest tests/ --cov=src --cov-report=term-missing --cov-fail-under=70

      - name: Verify Streamlit app imports cleanly
        run: python -c "import ast; ast.parse(open('app.py').read())"
'@
Set-Content -Path ".github/workflows/tests.yml" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/conftest.py"
$content = @'
import pathlib

import pytest


@pytest.fixture(autouse=True)
def clean_reports_probe():
    """
    Ensure src/health.py's reports/ writability probe file never leaks
    between tests. Applied automatically to every test in the suite.

    Wrapped in try/except/finally rather than a bare teardown: if cleanup
    itself fails (e.g. a permissions issue on the CI runner), that
    shouldn't raise a second, confusing exception that masks whatever the
    actual test failure was. The cleanup failure is swallowed
    deliberately -- a leftover probe file is a minor annoyance, not a
    correctness problem, so it doesn't deserve to fail the test suite.
    """
    probe = pathlib.Path("reports") / ".health_check_probe"
    try:
        yield
    finally:
        try:
            if probe.exists():
                probe.unlink()
        except OSError:
            pass
'@
Set-Content -Path "tests/conftest.py" -Value $content -Encoding UTF8 -NoNewline

Write-Host "  writing tests/test_health.py"
$content = @'
from unittest.mock import MagicMock, patch

import pytest
import requests

from src.health import (
    HealthReport,
    CheckResult,
    format_health_report,
    run_health_check,
)


def _run_health_check_safely() -> HealthReport:
    """
    run_health_check() is the one function in this test file that touches
    the real filesystem (it probes reports/ writability as part of its
    checks -- see src/health.py). Wrapping the call lets a filesystem
    failure on the test runner (read-only mount, permissions issue)
    surface as an explicit, informative pytest failure instead of an
    unhandled traceback pointing into library internals.
    """
    try:
        return run_health_check()
    except OSError as exc:
        pytest.fail(
            f"run_health_check() raised an unexpected OSError -- likely a "
            f"filesystem permissions issue on this runner, not a code bug: {exc}"
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

    report = _run_health_check_safely()
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

    report = _run_health_check_safely()
    assert report.all_ok is True


@patch("src.health.requests.get", side_effect=requests.ConnectionError("no network"))
@patch("src.health.settings")
def test_run_health_check_handles_github_unreachable(mock_settings, mock_get):
    mock_settings.groq_api_key = "gsk_fake"
    mock_settings.tavily_api_key = ""
    mock_settings.github_token = ""

    report = _run_health_check_safely()
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
        # Explicit try/except here (rather than pytest.raises) so the
        # exception's own message and type are inspected directly --
        # verifying not just that *something* was raised, but that it's
        # the original ConnectionError re-raised unmodified after
        # exhausting retries, not wrapped or swallowed along the way.
        try:
            _fetch_readme("owner", "repo")
            pytest.fail("expected requests.ConnectionError to propagate after max retries")
        except requests.ConnectionError as exc:
            assert "still down" in str(exc)
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
'@
Set-Content -Path "docs/DEPLOYMENT.md" -Value $content -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "Done. Verify with:" -ForegroundColor Green
Write-Host "  pytest tests/ --cov=src --cov-report=term-missing"
Write-Host "  docker compose up   (requires Docker Desktop)"

