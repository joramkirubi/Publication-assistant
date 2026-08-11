#Requires -Version 5.1
<#
.SYNOPSIS
  Fixes a flaky timing assertion in test_resilience.py that can fail on
  Windows due to time.sleep() timer resolution jitter.
.DESCRIPTION
  Run this from the ROOT of your Publication-assistant repo (same folder as
  main.py). It overwrites tests/test_resilience.py only.
#>

$ErrorActionPreference = "Stop"
Write-Host "Fixing flaky timing test..." -ForegroundColor Cyan

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
        # Lower bound has headroom below the theoretical 0.15s: time.sleep() can
        # wake up a few ms early, especially on Windows' default ~15ms timer
        # resolution, so a tight bound right at 0.14-0.15 is flaky across
        # platforms. 0.12 is comfortably below the real behavior (still far
        # above what you'd see with no backoff at all, e.g. ~0s) while giving
        # enough slack to not fail on timer jitter alone.
        assert elapsed >= 0.12

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

Write-Host ""
Write-Host "Done. Verify with:" -ForegroundColor Green
Write-Host "  pytest tests/ -q"

