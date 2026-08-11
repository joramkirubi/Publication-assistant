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