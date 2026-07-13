"""
Tests for the human-in-the-loop checkpoint added in response to Ready
Tensor reviewer feedback: the graph should genuinely pause before
Reviewer/Critic runs, allow inspection and editing of the suggested
tags/title/summary, and the edited values should actually reach the LLM
call inside Reviewer/Critic -- not just be accepted and silently ignored.
"""
from unittest.mock import MagicMock, patch

from src.graph import resume_pipeline, start_pipeline


@patch("src.agents.repo_analyzer.github_repo_reader")
@patch("src.agents.metadata_recommender.get_llm")
@patch("src.agents.content_improver.get_llm")
@patch("src.agents.content_improver.web_search")
@patch("src.agents.reviewer_critic.get_llm")
def test_graph_pauses_before_reviewer_critic(
    mock_reviewer_llm, mock_search, mock_content_llm, mock_metadata_llm, mock_gh
):
    mock_gh.invoke.return_value = {
        "owner": "acme", "repo": "widget",
        "readme": "# Widget\nDoes widget things.",
        "file_structure": ["README.md"],
        "metadata": {"language": "Python", "stars": 0, "license": "none", "topics": []},
    }
    mock_metadata_llm.return_value.invoke.return_value = MagicMock(content="OriginalTag")
    mock_content_llm.return_value.invoke.return_value = MagicMock(
        content="TITLE: Original Title\nSUMMARY: Original summary.\nPOSITIONING: none"
    )
    mock_search.invoke.return_value = {"results": []}

    app, config, paused_state = start_pipeline("https://github.com/acme/widget")

    # Reviewer/Critic's LLM must NOT have been called yet -- proof the
    # graph is genuinely paused before that node, not just about to run it.
    mock_reviewer_llm.return_value.invoke.assert_not_called()

    # The suggested fields from the two parallel agents should already be
    # visible for a human to inspect at this checkpoint.
    assert paused_state["suggested_title"] == "Original Title"
    assert "OriginalTag" in paused_state["suggested_tags"]
    assert "final_report" not in paused_state or not paused_state.get("final_report")


@patch("src.agents.repo_analyzer.github_repo_reader")
@patch("src.agents.metadata_recommender.get_llm")
@patch("src.agents.content_improver.get_llm")
@patch("src.agents.content_improver.web_search")
@patch("src.agents.reviewer_critic.get_llm")
def test_human_edit_actually_reaches_reviewer_llm_call(
    mock_reviewer_llm, mock_search, mock_content_llm, mock_metadata_llm, mock_gh
):
    """
    The core claim we're making to reviewers: a human's edit isn't just
    stored and ignored -- it changes what Reviewer/Critic actually sends
    to the LLM for the final report.
    """
    mock_gh.invoke.return_value = {
        "owner": "acme", "repo": "widget",
        "readme": "# Widget\nDoes widget things.",
        "file_structure": ["README.md"],
        "metadata": {"language": "Python", "stars": 0, "license": "none", "topics": []},
    }
    mock_metadata_llm.return_value.invoke.return_value = MagicMock(content="OriginalTag")
    mock_content_llm.return_value.invoke.return_value = MagicMock(
        content="TITLE: Original Title\nSUMMARY: Original summary.\nPOSITIONING: none"
    )
    mock_search.invoke.return_value = {"results": []}
    mock_reviewer_llm.return_value.invoke.return_value = MagicMock(content="## Summary\nfinal")

    app, config, paused_state = start_pipeline("https://github.com/acme/widget")

    # Human edits the title and leaves feedback, then we resume.
    human_edits = {
        "suggested_title": "Human-Edited Title",
        "human_feedback": "The original title was too generic.",
        "human_approved": True,
    }
    result = resume_pipeline(app, config, edits=human_edits)

    assert result["suggested_title"] == "Human-Edited Title"
    assert "final_report" in result

    # Inspect exactly what was sent to the LLM inside reviewer_critic_node.
    call_args = mock_reviewer_llm.return_value.invoke.call_args
    sent_messages = call_args[0][0]
    sent_text = "\n".join(m.content for m in sent_messages)
    assert "Human-Edited Title" in sent_text
    assert "The original title was too generic." in sent_text


@patch("src.agents.repo_analyzer.github_repo_reader")
@patch("src.agents.metadata_recommender.get_llm")
@patch("src.agents.content_improver.get_llm")
@patch("src.agents.content_improver.web_search")
@patch("src.agents.reviewer_critic.get_llm")
def test_resume_with_no_edits_keeps_original_suggestions(
    mock_reviewer_llm, mock_search, mock_content_llm, mock_metadata_llm, mock_gh
):
    """Approving as-is (no edits) should carry the original suggestions through unchanged."""
    mock_gh.invoke.return_value = {
        "owner": "acme", "repo": "widget",
        "readme": "# Widget\nDoes widget things.",
        "file_structure": ["README.md"],
        "metadata": {"language": "Python", "stars": 0, "license": "none", "topics": []},
    }
    mock_metadata_llm.return_value.invoke.return_value = MagicMock(content="OriginalTag")
    mock_content_llm.return_value.invoke.return_value = MagicMock(
        content="TITLE: Original Title\nSUMMARY: Original summary.\nPOSITIONING: none"
    )
    mock_search.invoke.return_value = {"results": []}
    mock_reviewer_llm.return_value.invoke.return_value = MagicMock(content="## Summary\nfinal")

    app, config, _ = start_pipeline("https://github.com/acme/widget")
    result = resume_pipeline(app, config, edits=None)

    assert result["suggested_title"] == "Original Title"
    assert "final_report" in result
