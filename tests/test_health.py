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