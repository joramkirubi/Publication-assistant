"""
Orchestration graph.

Flow:

    START -> repo_analyzer -> metadata_recommender -> reviewer_critic -> END
                            -> content_improver     -^

repo_analyzer runs first (everything downstream needs the README).
metadata_recommender and content_improver then run as parallel branches,
since neither depends on the other's output — this is a deliberate design
choice to cut latency, not just an artifact of the framework.
reviewer_critic fans back in, waiting on both branches, and produces the
final report.
"""
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

    return graph.compile()


def run_pipeline(repo_url: str, user_description: str | None = None) -> PublicationAssistantState:
    app = build_graph()
    initial_state: PublicationAssistantState = {
        "repo_url": repo_url,
        "user_description": user_description or "",
        "errors": [],
    }
    result = app.invoke(initial_state)
    return result
