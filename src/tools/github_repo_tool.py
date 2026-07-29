"""
Tool: GitHubRepoTool

Fetches a public GitHub repository's README content and top-level file
structure via the GitHub REST API. No git clone is required, which keeps
the tool fast and dependency-light.
"""
import base64
import re
from typing import Optional

import requests
from langchain_core.tools import tool

from src.config import settings
from src.resilience import with_retry

GITHUB_API_ROOT = "https://api.github.com"

# Retried on connection/timeout errors and 5xx/429 responses (raised via
# resp.raise_for_status()) -- NOT on 404s, which _fetch_readme handles
# explicitly, or 4xx client errors in general, since retrying a request
# that's wrong won't make it right.
_github_retry = with_retry(
    max_attempts=3,
    base_delay=1.0,
    exceptions=(requests.ConnectionError, requests.Timeout, requests.HTTPError),
)


def _parse_owner_repo(repo_url: str) -> tuple[str, str]:
    """Extract (owner, repo) from a GitHub URL like https://github.com/owner/repo(.git)"""
    match = re.search(r"github\.com[:/]+([^/]+)/([^/.]+)", repo_url.strip())
    if not match:
        raise ValueError(f"Could not parse a GitHub owner/repo from: {repo_url!r}")
    return match.group(1), match.group(2)


def _headers() -> dict:
    headers = {"Accept": "application/vnd.github+json"}
    if settings.github_token:
        headers["Authorization"] = f"Bearer {settings.github_token}"
    return headers


@_github_retry
def _fetch_readme(owner: str, repo: str) -> str:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}/readme"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    if resp.status_code == 404:
        return "(No README found in this repository.)"
    resp.raise_for_status()
    data = resp.json()
    content = base64.b64decode(data["content"]).decode("utf-8", errors="replace")
    return content[: settings.max_readme_chars]


@_github_retry
def _fetch_top_level_structure(owner: str, repo: str) -> list[str]:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}/contents/"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    resp.raise_for_status()
    items = resp.json()
    entries = []
    for item in items:
        marker = "/" if item["type"] == "dir" else ""
        entries.append(f"{item['name']}{marker}")
    return sorted(entries)


@_github_retry
def _fetch_repo_metadata(owner: str, repo: str) -> dict:
    url = f"{GITHUB_API_ROOT}/repos/{owner}/{repo}"
    resp = requests.get(url, headers=_headers(), timeout=settings.request_timeout)
    resp.raise_for_status()
    data = resp.json()
    return {
        "description": data.get("description") or "",
        "stars": data.get("stargazers_count", 0),
        "language": data.get("language") or "unknown",
        "topics": data.get("topics", []),
        "license": (data.get("license") or {}).get("name", "none"),
        "open_issues": data.get("open_issues_count", 0),
    }


@tool("github_repo_reader")
def github_repo_reader(repo_url: str) -> dict:
    """
    Fetch the README text, top-level file structure, and basic metadata
    (stars, language, license, topics) for a public GitHub repository.

    Args:
        repo_url: A GitHub repository URL, e.g. https://github.com/owner/repo

    Returns:
        A dict with keys: owner, repo, readme, file_structure, metadata.
    """
    owner, repo = _parse_owner_repo(repo_url)
    readme = _fetch_readme(owner, repo)
    structure = _fetch_top_level_structure(owner, repo)
    metadata = _fetch_repo_metadata(owner, repo)
    return {
        "owner": owner,
        "repo": repo,
        "readme": readme,
        "file_structure": structure,
        "metadata": metadata,
    }