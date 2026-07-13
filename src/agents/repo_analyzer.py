"""
Agent: Repo Analyzer

ROLE: Data-gathering specialist and entry point of the pipeline.
SPECIALIZATION: Interfacing with the GitHub REST API; owns no LLM
reasoning at all — this agent is deliberately "dumb" and mechanical, so a
GitHub outage or bad URL fails predictably rather than producing a
plausible-sounding but wrong result.
READS FROM STATE: repo_url
WRITES TO STATE: owner, repo, readme_text, file_structure, repo_metadata, errors
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
            "errors": [f"RepoAnalyzer: failed to fetch repo — {exc}"],
        }

    return {
        "owner": result["owner"],
        "repo": result["repo"],
        "readme_text": result["readme"],
        "file_structure": result["file_structure"],
        "repo_metadata": result["metadata"],
        "errors": [],
    }
