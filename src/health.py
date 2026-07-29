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