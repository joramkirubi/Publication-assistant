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