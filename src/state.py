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

    # ---- populated by the human-in-the-loop checkpoint (main.py) ----
    # The graph pauses right before ReviewerCritic so a person can review
    # and optionally edit the suggested tags/title/summary above, and
    # optionally leave free-text feedback. ReviewerCritic reads these when
    # it finally runs, so human input genuinely shapes the final report
    # rather than just being logged for show.
    human_approved: bool
    human_feedback: str

    # ---- bookkeeping ----
    # MetadataRecommender and ContentImprover run in parallel and can both
    # write here in the same step. `operator.add` tells LangGraph to
    # concatenate the lists each node returns rather than erroring on the
    # simultaneous write - so each node should return only ITS OWN new
    # error(s) here, not a copy of the full accumulated list.
    errors: Annotated[list[str], operator.add]