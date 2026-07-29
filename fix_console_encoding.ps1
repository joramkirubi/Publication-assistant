#Requires -Version 5.1
<#
.SYNOPSIS
  Fixes garbled console output (mojibake) by replacing Unicode box-drawing
  characters and emoji with plain ASCII in CLI-facing code.
.DESCRIPTION
  Run this from the ROOT of your Publication-assistant repo (same folder as
  main.py). It overwrites main.py, src/health.py, and docs/TROUBLESHOOTING.md.
#>

$ErrorActionPreference = "Stop"
Write-Host "Fixing console output encoding issues..." -ForegroundColor Cyan

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
    print("== Human Review Checkpoint ==============================")
    print(f"Suggested title:   {paused_state.get('suggested_title') or '(none)'}")
    print(f"Suggested summary: {paused_state.get('suggested_summary') or '(none)'}")
    tags = paused_state.get("suggested_tags") or []
    print(f"Suggested tags:    {', '.join(tags) if tags else '(none)'}")
    print()

    while True:
        answer = input("Approve as-is? [Y/n/e=edit]: ").strip().lower()
        if answer in ("", "y", "n", "e"):
            break
        print(f"  '{answer}' isn't a valid choice - please type Y, n, or e.")

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
        print(f"[ERROR] Invalid input: {exc}")
        return 1

    if paused_state.get("errors"):
        print("[WARNING] Warnings/errors encountered so far:")
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
        print(f"\n[ERROR] The pipeline hit an unexpected error and could not finish: {exc}")
        print("   (This is unusual -- individual agent failures normally degrade gracefully.")
        print("    Check the log above, or run --health-check to verify your setup.)")
        return 1

    if result.get("errors"):
        print("\n[WARNING] Warnings/errors encountered during the run:")
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
    print(f"\n[OK] Report saved to {output_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
'@
Set-Content -Path "main.py" -Value $content -Encoding UTF8 -NoNewline

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
    lines = ["== Health Check =========================================="]
    for check in report.checks:
        icon = "[OK]" if check.ok else "[FAIL]"
        label = check.name.replace("optional:", "") + (
            " (optional)" if check.name.startswith("optional:") else ""
        )
        lines.append(f"{icon} {label}: {check.detail}")
    lines.append("")
    lines.append("Overall: " + ("[OK] healthy" if report.all_ok else "[FAIL] unhealthy"))
    return "\n".join(lines)
'@
Set-Content -Path "src/health.py" -Value $content -Encoding UTF8 -NoNewline

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

### `GitHub API: unreachable (... getaddrinfo failed ...)` in `--health-check`

This is a DNS resolution failure on your machine, not an application bug
-- Python couldn't resolve `api.github.com` to an IP address. Common
causes and fixes:

- **VPN or corporate/school network** blocking or rerouting DNS. Try
  disconnecting the VPN, or check with your network admin.
- **A misconfigured or unreachable DNS server.** Test with:
  ```powershell
  Resolve-DnsName api.github.com
  ```
  If that also fails, try switching your DNS (e.g. to `8.8.8.8` in your
  network adapter settings) or check whether other sites resolve at all.
- **A flaky Wi-Fi/network connection** -- retry the health check; the
  underlying GitHub calls the pipeline makes already retry transient
  failures automatically (see [ARCHITECTURE.md](ARCHITECTURE.md)), but
  a `--health-check` DNS failure itself isn't retried since it's meant to
  fail fast and tell you immediately.
- **Antivirus/firewall software** intercepting HTTPS connections. Check
  if temporarily disabling it changes the result (then re-enable it).

If `GROQ_API_KEY` shows `[OK]` but GitHub shows `[FAIL]` for this reason,
the pipeline itself will likely still fail on `RepoAnalyzer` for the same
DNS reason -- fix connectivity first before running a real analysis.

### Console shows garbled characters like `â”€â”€` or `âœ…` instead of the health check / report symbols

This is a PowerShell console encoding mismatch (the app prints UTF-8,
but your console's active code page is something else, commonly on
Windows). All CLI-facing output in this project is written in
plain ASCII precisely to avoid this, so if you see mojibake like this,
you're most likely on an outdated copy of `main.py` / `src/health.py` --
re-run the setup script or re-pull the latest version. If it persists on
current code, you can also force UTF-8 for the session with:
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
```


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

Write-Host ""
Write-Host "Done. Verify with:" -ForegroundColor Green
Write-Host "  python main.py --health-check"
Write-Host "  pytest tests/ -q"

