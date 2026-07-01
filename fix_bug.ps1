# Auto-generated fix script for the InvalidUpdateError bug.
# Run this from inside the publication-assistant folder:
#   powershell -ExecutionPolicy Bypass -File fix_bug.ps1
# It overwrites the 6 affected files with corrected versions.

Write-Host "Applying fix..." -ForegroundColor Cyan

$content = @'
"""
Shared state that flows through the LangGraph graph. Every agent node reads
from and writes to this single TypedDict, which is how the agents
"communicate" and coordinate in this system.
"""
import operator
from typing import Annotated, Optional, TypedDict


class PublicationAssistantState(TypedDict, total=False):
    # ---- input ----
    repo_url: str
    user_description: Optional[str]

    # ---- populated by RepoAnalyzerAgent ----
    owner: str
    repo: str
    readme_text: str
    file_structure: list[str]
    repo_metadata: dict

    # ---- populated by MetadataRecommenderAgent ----
    suggested_keywords: list[str]
    suggested_tags: list[str]

    # ---- populated by ContentImproverAgent ----
    suggested_title: str
    suggested_summary: str
    positioning_notes: str

    # ---- populated by ReviewerCriticAgent ----
    structure_report: dict
    review_notes: list[str]
    final_report: str

    # ---- bookkeeping ----
    # MetadataRecommender and ContentImprover run in parallel and can both
    # write here in the same step. `operator.add` tells LangGraph to
    # concatenate the lists each node returns rather than erroring on the
    # simultaneous write — so each node should return only ITS OWN new
    # error(s) here, not a copy of the full accumulated list.
    errors: Annotated[list[str], operator.add]
'@
Set-Content -Path "src\state.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated src\state.py"

$content = @'
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
'@
Set-Content -Path "src\agents\repo_analyzer.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated src\agents\repo_analyzer.py"

$content = @'
"""
Agent: Metadata Recommender

Role: suggests tags/categories/keywords for the project. Combines a
deterministic keyword-extraction tool with an LLM pass that filters the
raw candidates down to ones that would actually make good Ready Tensor
publication tags (specific, not generic English words).
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm
from src.state import PublicationAssistantState
from src.tools.keyword_extractor_tool import keyword_extractor

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are a metadata specialist for Ready Tensor, a platform for AI/ML \
publications. You are given a raw list of candidate keywords extracted from a \
project's README, plus the README text itself. Your job is to select and refine \
the best 5-8 tags for this project's publication listing.

Good tags are specific (e.g. "LangGraph", "RAG", "MultiAgentSystems"), not generic \
English words. Prefer CamelCase or hyphenated multi-word tags where natural, \
consistent with how Ready Tensor publications are tagged.

Respond with ONLY a comma-separated list of tags, nothing else."""


def metadata_recommender_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")

    if not readme_text:
        return {
            "suggested_keywords": [],
            "suggested_tags": [],
            "errors": ["MetadataRecommender: skipped, no README text available."],
        }

    raw = keyword_extractor.invoke({"text": readme_text, "top_n": 15})
    candidate_keywords = raw["keywords"]
    new_errors = []

    try:
        llm = get_llm(temperature=0.2)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"Candidate keywords: {', '.join(candidate_keywords)}\n\n"
                    f"README excerpt:\n{readme_text[:3000]}"
                )
            ),
        ]
        response = llm.invoke(messages)
        tags = [t.strip() for t in response.content.split(",") if t.strip()]
    except Exception as exc:  # noqa: BLE001
        logger.exception("metadata_recommender_node LLM call failed")
        new_errors.append(f"MetadataRecommender: LLM refinement failed ({exc}), using raw tags.")
        tags = raw["suggested_tags"]

    return {
        "suggested_keywords": candidate_keywords,
        "suggested_tags": tags,
        "errors": new_errors,
    }
'@
Set-Content -Path "src\agents\metadata_recommender.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated src\agents\metadata_recommender.py"

$content = @'
"""
Agent: Content Improver

Role: proposes a better title and summary for the project. Uses the web
search tool to gather a little positioning context (how similar projects
are titled/described), then asks the LLM to draft improved copy grounded
in the actual README content (to avoid hallucinated claims).
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm
from src.state import PublicationAssistantState
from src.tools.web_search_tool import web_search

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are an editorial specialist for Ready Tensor publications. \
Given a project's README and some web context about similarly positioned projects, \
propose:

1. A specific, discoverable title (avoid vague titles like "My Project")
2. A 2-3 sentence summary that clearly states what the project does and why it matters
3. One sentence of positioning notes: how this project compares to similar ones you saw

Ground every claim in the README content provided — do not invent features, \
performance numbers, or capabilities that aren't described in the README.

Respond in exactly this format:
TITLE: <title>
SUMMARY: <summary>
POSITIONING: <positioning notes>"""


def content_improver_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    repo_name = state.get("repo", "")

    if not readme_text:
        return {
            "suggested_title": "",
            "suggested_summary": "",
            "positioning_notes": "",
            "errors": ["ContentImprover: skipped, no README text available."],
        }

    search_query = f"{repo_name} AI ML GitHub project similar tools"
    search_result = web_search.invoke({"query": search_query, "max_results": 5})
    context_snippets = "\n".join(
        f"- {r['title']}: {r['snippet']}" for r in search_result.get("results", [])
    ) or "(no web context available)"

    new_errors = []
    try:
        llm = get_llm(temperature=0.4)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"README:\n{readme_text[:4000]}\n\n"
                    f"Similar projects found via web search:\n{context_snippets}"
                )
            ),
        ]
        response = llm.invoke(messages)
        text = response.content

        title = _extract_field(text, "TITLE")
        summary = _extract_field(text, "SUMMARY")
        positioning = _extract_field(text, "POSITIONING")
    except Exception as exc:  # noqa: BLE001
        logger.exception("content_improver_node LLM call failed")
        new_errors.append(f"ContentImprover: LLM drafting failed ({exc}).")
        title, summary, positioning = "", "", ""

    return {
        "suggested_title": title,
        "suggested_summary": summary,
        "positioning_notes": positioning,
        "errors": new_errors,
    }


def _extract_field(text: str, field: str) -> str:
    for line in text.splitlines():
        if line.strip().upper().startswith(field.upper() + ":"):
            return line.split(":", 1)[1].strip()
    return ""
'@
Set-Content -Path "src\agents\content_improver.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated src\agents\content_improver.py"

$content = @'
"""
Agent: Reviewer / Critic

Role: the final agent in the pipeline. Runs the deterministic README
structure checker against Ready Tensor's Essential/Professional criteria,
then synthesizes everything the other three agents produced into one
final, human-readable report the user can act on.
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.llm import get_llm
from src.state import PublicationAssistantState
from src.tools.readme_structure_tool import readme_structure_checker

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are the final reviewer in a multi-agent publication assistant \
pipeline. You receive: the original README, a structural analysis (which standard \
sections are present/missing), suggested tags, and a suggested title/summary from \
other agents.

Write a concise, actionable final report in markdown with these sections:
## Summary of Findings
## Suggested Title & Summary
## Suggested Tags
## Missing Sections (with a one-line fix suggestion for each)
## Overall Recommendation (2-3 sentences)

Be specific and grounded in the actual data provided. Do not repeat the full README."""


def reviewer_critic_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    prior_errors = state.get("errors", [])

    structure_report = readme_structure_checker.invoke({"readme_text": readme_text})

    review_notes = []
    if structure_report["missing_essential"]:
        review_notes.append(
            "Missing essential sections: " + ", ".join(structure_report["missing_essential"])
        )
    if structure_report["missing_professional"]:
        review_notes.append(
            "Missing professional-tier sections: "
            + ", ".join(structure_report["missing_professional"])
        )
    if prior_errors:
        review_notes.append("Upstream agent issues: " + "; ".join(prior_errors))

    new_errors = []
    try:
        llm = get_llm(temperature=0.2)
        messages = [
            SystemMessage(content=SYSTEM_PROMPT),
            HumanMessage(
                content=(
                    f"Structure report: {structure_report}\n\n"
                    f"Suggested tags: {state.get('suggested_tags', [])}\n\n"
                    f"Suggested title: {state.get('suggested_title', '')}\n"
                    f"Suggested summary: {state.get('suggested_summary', '')}\n"
                    f"Positioning notes: {state.get('positioning_notes', '')}\n\n"
                    f"README excerpt:\n{readme_text[:2000]}"
                )
            ),
        ]
        response = llm.invoke(messages)
        final_report = response.content
    except Exception as exc:  # noqa: BLE001
        logger.exception("reviewer_critic_node LLM call failed")
        new_errors.append(f"ReviewerCritic: final synthesis failed ({exc}).")
        final_report = (
            "# Final report unavailable (LLM call failed)\n\n"
            f"Structure report: {structure_report}\n"
            f"Suggested tags: {state.get('suggested_tags', [])}\n"
        )

    return {
        "structure_report": structure_report,
        "review_notes": review_notes,
        "final_report": final_report,
        "errors": new_errors,
    }
'@
Set-Content -Path "src\agents\reviewer_critic.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated src\agents\reviewer_critic.py"

$content = @'
"""
These tests mock out the GitHub API and the LLM client so the agent *logic*
(state in -> state out, error handling) can be verified without needing real
API keys or network access. End-to-end behavior with real APIs should be
verified manually via `python main.py --repo <url>` once keys are configured.
"""
from unittest.mock import MagicMock, patch

from src.agents.content_improver import content_improver_node
from src.agents.metadata_recommender import metadata_recommender_node
from src.agents.repo_analyzer import repo_analyzer_node
from src.agents.reviewer_critic import reviewer_critic_node
from src.graph import run_pipeline


@patch("src.agents.repo_analyzer.github_repo_reader")
def test_repo_analyzer_node_populates_state(mock_tool):
    mock_tool.invoke.return_value = {
        "owner": "acme",
        "repo": "widget",
        "readme": "# Widget\n## Installation\npip install widget",
        "file_structure": ["README.md", "src/"],
        "metadata": {"language": "Python", "stars": 10, "license": "MIT", "topics": []},
    }
    result = repo_analyzer_node({"repo_url": "https://github.com/acme/widget", "errors": []})
    assert result["owner"] == "acme"
    assert "Installation" in result["readme_text"]
    assert result["errors"] == []


@patch("src.agents.repo_analyzer.github_repo_reader")
def test_repo_analyzer_node_handles_fetch_failure_gracefully(mock_tool):
    mock_tool.invoke.side_effect = ValueError("bad url")
    result = repo_analyzer_node({"repo_url": "not-a-url", "errors": []})
    assert result["readme_text"] == ""
    assert len(result["errors"]) == 1
    assert "RepoAnalyzer" in result["errors"][0]


@patch("src.agents.metadata_recommender.get_llm")
def test_metadata_recommender_node_returns_tags(mock_get_llm):
    mock_llm = MagicMock()
    mock_llm.invoke.return_value = MagicMock(content="LangGraph, RAG, MultiAgentSystems")
    mock_get_llm.return_value = mock_llm

    state = {"readme_text": "This uses LangGraph and RAG for multi-agent systems.", "errors": []}
    result = metadata_recommender_node(state)
    assert "LangGraph" in result["suggested_tags"]
    assert len(result["suggested_keywords"]) > 0


def test_metadata_recommender_node_skips_when_no_readme():
    result = metadata_recommender_node({"readme_text": "", "errors": []})
    assert result["suggested_tags"] == []
    assert "MetadataRecommender" in result["errors"][0]


@patch("src.agents.content_improver.get_llm")
@patch("src.agents.content_improver.web_search")
def test_content_improver_node_parses_llm_output(mock_search, mock_get_llm):
    mock_search.invoke.return_value = {"results": []}
    mock_llm = MagicMock()
    mock_llm.invoke.return_value = MagicMock(
        content="TITLE: Widget Toolkit\nSUMMARY: A great widget tool.\nPOSITIONING: Similar to Foo."
    )
    mock_get_llm.return_value = mock_llm

    state = {"readme_text": "# Widget\nDoes widget things.", "repo": "widget", "errors": []}
    result = content_improver_node(state)
    assert result["suggested_title"] == "Widget Toolkit"
    assert result["suggested_summary"] == "A great widget tool."


@patch("src.agents.reviewer_critic.get_llm")
def test_reviewer_critic_node_produces_final_report(mock_get_llm):
    mock_llm = MagicMock()
    mock_llm.invoke.return_value = MagicMock(content="## Summary of Findings\nLooks good.")
    mock_get_llm.return_value = mock_llm

    state = {
        "readme_text": "# Widget\n## License\nMIT",
        "suggested_tags": ["Widget"],
        "suggested_title": "Widget Toolkit",
        "suggested_summary": "A tool.",
        "positioning_notes": "",
        "errors": [],
    }
    result = reviewer_critic_node(state)
    assert "final_report" in result
    assert result["structure_report"]["essential_score"].endswith("/5")


@patch("src.agents.repo_analyzer.github_repo_reader")
@patch("src.agents.metadata_recommender.get_llm")
@patch("src.agents.content_improver.get_llm")
@patch("src.agents.content_improver.web_search")
@patch("src.agents.reviewer_critic.get_llm")
def test_pipeline_survives_simultaneous_errors_in_parallel_branches(
    mock_reviewer_llm, mock_search, mock_content_llm, mock_metadata_llm, mock_gh
):
    """
    Regression test: MetadataRecommender and ContentImprover run as parallel
    LangGraph branches and both write to the shared `errors` list. Without
    a reducer on that field, LangGraph raises InvalidUpdateError when both
    branches write in the same step. This confirms the fix holds and both
    errors are preserved for the Reviewer to see.
    """
    mock_gh.invoke.return_value = {
        "owner": "acme", "repo": "widget",
        "readme": "# Widget\nDoes widget things.",
        "file_structure": ["README.md"],
        "metadata": {"language": "Python", "stars": 0, "license": "none", "topics": []},
    }
    mock_metadata_llm.return_value.invoke.side_effect = RuntimeError("provider rate limited")
    mock_content_llm.return_value.invoke.side_effect = RuntimeError("provider rate limited")
    mock_search.invoke.return_value = {"results": []}
    mock_reviewer_llm.return_value.invoke.return_value = MagicMock(content="## Summary\nOK")

    result = run_pipeline("https://github.com/acme/widget")

    assert "final_report" in result
    assert len(result["errors"]) == 2
'@
Set-Content -Path "tests\test_agents_with_mocks.py" -Value $content -Encoding utf8 -NoNewline
Write-Host "  updated tests\test_agents_with_mocks.py"

Write-Host ""
Write-Host "Done. Now run:" -ForegroundColor Green
Write-Host "  pytest tests\ -v"
Write-Host "  python main.py --repo https://github.com/joramkirubi/medical-rag-assistant"