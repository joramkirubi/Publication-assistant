"""
Agent: Repo Analyzer

Role: the entry point of the pipeline. Fetches the repo's README, file
structure, and metadata via the GitHub tool, and writes it into shared
state for downstream agents to use.
"""
import logging

from src.state import PublicationAssistantState
from src.tools.github_repo_tool import github_repo_reader

logger = logging.getLogger(__name__)


def repo_analyzer_node(state: PublicationAssistantState) -> dict:
    repo_url = state["repo_url"]

    try:
        result = github_repo_reader.invoke({"repo_url": repo_url})
    except Exception as exc:  # noqa: BLE001 - surfaced to the user via state
        logger.exception("repo_analyzer_node failed")
        return {
            "readme_text": "",
            "file_structure": [],
            "repo_metadata": {},
            "errors": [f"RepoAnalyzer: failed to fetch repo â€” {exc}"],
        }

    return {
        "owner": result["owner"],
        "repo": result["repo"],
        "readme_text": result["readme"],
        "file_structure": result["file_structure"],
        "repo_metadata": result["metadata"],
        "errors": [],
    }