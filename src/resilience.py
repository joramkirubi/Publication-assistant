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