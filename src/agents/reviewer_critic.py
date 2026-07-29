"""
Agent: Reviewer / Critic

ROLE: Final synthesizer and quality gate â€” the last agent in the pipeline.
SPECIALIZATION: Objective structural compliance checking (via a
deterministic tool, not an LLM opinion) plus synthesis of everything the
other three agents produced into one final, human-readable report.
READS FROM STATE: readme_text, suggested_tags, suggested_title,
    suggested_summary, positioning_notes, errors, human_approved,
    human_feedback (the last two are populated by the human-in-the-loop
    checkpoint in main.py, which pauses the graph right before this agent
    runs).
WRITES TO STATE: structure_report, review_notes, final_report, errors.
"""
import logging

from langchain_core.messages import HumanMessage, SystemMessage

from src.guardrails import filter_output
from src.llm import get_llm, invoke_llm
from src.state import PublicationAssistantState
from src.tools.readme_structure_tool import readme_structure_checker

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are the final reviewer in a multi-agent publication assistant \
pipeline. You receive: the original README, a structural analysis (which standard \
sections are present/missing), suggested tags, a suggested title/summary from other \
agents, and â€” if a human reviewed this run â€” their approval status and any free-text \
feedback they left.

Write a concise, actionable final report in markdown with these sections:
## Summary of Findings
## Suggested Title & Summary
## Suggested Tags
## Missing Sections (with a one-line fix suggestion for each)
## Overall Recommendation (2-3 sentences)

If human feedback is present, weave it into your recommendation explicitly â€” e.g. if \
they said a tag was wrong or a title didn't fit, acknowledge that and adjust your \
final recommendation accordingly rather than ignoring it.

Be specific and grounded in the actual data provided. Do not repeat the full README."""


def reviewer_critic_node(state: PublicationAssistantState) -> dict:
    readme_text = state.get("readme_text", "")
    prior_errors = state.get("errors", [])
    human_feedback = state.get("human_feedback", "")
    human_approved = state.get("human_approved", True)

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
    if human_feedback:
        review_notes.append(f"Human feedback: {human_feedback}")

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
                    f"Human reviewed and approved: {human_approved}\n"
                    f"Human feedback: {human_feedback or '(none given)'}\n\n"
                    f"README excerpt:\n{readme_text[:2000]}"
                )
            ),
        ]
        response = invoke_llm(llm, messages)
        final_report = filter_output(response.content)
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