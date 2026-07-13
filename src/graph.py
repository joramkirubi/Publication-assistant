"""
Orchestration graph.

Flow:

    START -> repo_analyzer -> metadata_recommender -> [HUMAN REVIEW] -> reviewer_critic -> END
                            -> content_improver     -^

repo_analyzer runs first (everything downstream needs the README).
metadata_recommender and content_improver then run as parallel branches,
since neither depends on the other's output — this is a deliberate design
choice to cut latency, not just an artifact of the framework.

Before reviewer_critic runs, the graph PAUSES (a static interrupt) so a
human can inspect the suggested tags/title/summary, optionally edit them,
and optionally leave free-text feedback. reviewer_critic then runs with
whatever the human approved, edited, or commented on — this is a real
human-in-the-loop checkpoint, not just a log statement.
"""
import uuid

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, StateGraph

from src.agents import (
    content_improver_node,
    metadata_recommender_node,
    repo_analyzer_node,
    reviewer_critic_node,
)
from src.state import PublicationAssistantState


def build_graph():
    graph = StateGraph(PublicationAssistantState)

    graph.add_node("repo_analyzer", repo_analyzer_node)
    graph.add_node("metadata_recommender", metadata_recommender_node)
    graph.add_node("content_improver", content_improver_node)
    graph.add_node("reviewer_critic", reviewer_critic_node)

    graph.set_entry_point("repo_analyzer")

    graph.add_edge("repo_analyzer", "metadata_recommender")
    graph.add_edge("repo_analyzer", "content_improver")

    graph.add_edge("metadata_recommender", "reviewer_critic")
    graph.add_edge("content_improver", "reviewer_critic")

    graph.add_edge("reviewer_critic", END)

    checkpointer = InMemorySaver()
    # interrupt_before pauses the graph right before the named node runs,
    # so the human reviews/edits state BEFORE that node acts on it —
    # the right choice here since we want to gate what Reviewer/Critic
    # sees, not review something it already did (that would be
    # interrupt_after instead).
    return graph.compile(checkpointer=checkpointer, interrupt_before=["reviewer_critic"])


def start_pipeline(repo_url: str, user_description: str | None = None):
    """
    Runs the pipeline up to the human-in-the-loop checkpoint (paused right
    before Reviewer/Critic). Returns (app, config, paused_state) so the
    caller can inspect and optionally edit state before calling
    resume_pipeline().

    `config` carries the thread_id the checkpointer uses to know which
    paused run to resume later — it must be passed back into
    resume_pipeline() unchanged.
    """
    app = build_graph()
    config = {"configurable": {"thread_id": str(uuid.uuid4())}}
    initial_state: PublicationAssistantState = {
        "repo_url": repo_url,
        "user_description": user_description or "",
        "errors": [],
    }
    app.invoke(initial_state, config)
    paused_state = app.get_state(config).values
    return app, config, paused_state


def resume_pipeline(app, config, edits: dict | None = None) -> PublicationAssistantState:
    """
    Optionally applies human edits/feedback to the paused state, then
    resumes execution through Reviewer/Critic to completion.
    """
    if edits:
        # as_node is required here: this graph has two parallel branches
        # (metadata_recommender and content_improver) that write to state in
        # the same step. LangGraph normally infers which node an update
        # should be attributed to by looking at which node wrote most
        # recently -- but with two nodes writing simultaneously, it can't
        # pick one and raises InvalidUpdateError("Ambiguous update").
        # Explicitly attributing human edits to content_improver resolves
        # this; it's internal bookkeeping only and does not change which
        # fields get updated or their values.
        app.update_state(config, edits, as_node="content_improver")
    return app.invoke(None, config)


def run_pipeline(repo_url: str, user_description: str | None = None) -> PublicationAssistantState:
    """
    Convenience wrapper that runs the full pipeline with no human review
    step (auto-approves). Used by the test suite and anywhere a
    non-interactive run is needed.
    """
    app, config, _ = start_pipeline(repo_url, user_description)
    return resume_pipeline(app, config, edits=None)
