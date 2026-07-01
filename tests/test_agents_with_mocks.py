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