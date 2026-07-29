"""
Streamlit UI for the Publication Assistant multi-agent system.

Run with:
    streamlit run app.py

This is a thin presentation layer over src/graph.py -- it does not
duplicate any pipeline/agent logic, only handles input collection, the
human-in-the-loop review step, and result display/download.
"""
import logging
from datetime import datetime

import streamlit as st

from src.graph import resume_pipeline, start_pipeline
from src.guardrails import GuardrailViolation
from src.health import format_health_report, run_health_check

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

st.set_page_config(page_title="Publication Assistant", layout="centered")


def _init_session_state() -> None:
    defaults = {
        "stage": "input",  # input -> review -> done
        "app": None,
        "config": None,
        "paused_state": None,
        "result": None,
        "repo_input": "",
    }
    for key, value in defaults.items():
        if key not in st.session_state:
            st.session_state[key] = value


def _reset() -> None:
    for key in ("stage", "app", "config", "paused_state", "result"):
        st.session_state.pop(key, None)
    _init_session_state()


def _render_sidebar() -> None:
    with st.sidebar:
        st.header("System status")
        if st.button("Run health check"):
            with st.spinner("Checking configuration and connectivity..."):
                report = run_health_check()
            st.code(format_health_report(report), language=None)
            if not report.all_ok:
                st.error("Some required checks failed -- see above.")
        st.divider()
        st.caption(
            "Four agents (Repo Analyzer, Metadata Recommender, Content Improver, "
            "Reviewer/Critic) run in a LangGraph pipeline with a human-in-the-loop "
            "checkpoint before the final report is generated."
        )
        if st.button("Start over"):
            _reset()
            st.rerun()


def _render_input_stage() -> None:
    st.title("Publication Assistant")
    st.write(
        "Give it a public GitHub repo URL. It reviews the README, suggests a "
        "better title/summary/tags, and flags missing documentation sections "
        "-- grounded in Ready Tensor's Open Source Repository Guide."
    )

    with st.form("repo_form"):
        repo_url = st.text_input(
            "GitHub repository URL",
            placeholder="https://github.com/owner/repo",
        )
        description = st.text_area(
            "Optional project description (helps the agents with context)",
            max_chars=500,
            height=80,
        )
        submitted = st.form_submit_button("Analyze repository", type="primary")

    if submitted:
        try:
            with st.spinner("Fetching repo and running Repo Analyzer, Metadata Recommender, "
                             "and Content Improver..."):
                app, config, paused_state = start_pipeline(repo_url, description)
        except GuardrailViolation as exc:
            st.error(f"Invalid input: {exc}")
            return
        except Exception as exc:  # noqa: BLE001 - surfaced to the user, not a silent failure
            logger.exception("Pipeline failed to start")
            st.error(f"Something went wrong starting the pipeline: {exc}")
            return

        st.session_state.app = app
        st.session_state.config = config
        st.session_state.paused_state = paused_state
        st.session_state.stage = "review"
        st.rerun()


def _render_review_stage() -> None:
    st.title("Publication Assistant")
    st.subheader("Human Review Checkpoint")
    st.write(
        "The pipeline is paused here, right before the final report is written. "
        "Review or edit the suggestions below before continuing."
    )

    paused_state = st.session_state.paused_state

    if paused_state.get("errors"):
        with st.expander("Warnings from earlier steps", expanded=False):
            for err in paused_state["errors"]:
                st.write(f"- {err}")

    with st.form("review_form"):
        title = st.text_input("Suggested title", value=paused_state.get("suggested_title") or "")
        summary = st.text_area(
            "Suggested summary", value=paused_state.get("suggested_summary") or "", height=100
        )
        tags = st.text_input(
            "Suggested tags (comma-separated)",
            value=", ".join(paused_state.get("suggested_tags") or []),
        )
        feedback = st.text_area(
            "Feedback for the Reviewer/Critic agent (optional)",
            placeholder="e.g. 'the summary undersells the RAG component'",
            height=80,
        )
        col1, col2 = st.columns(2)
        approve = col1.form_submit_button("Approve & generate final report", type="primary")
        reject = col2.form_submit_button("Reject suggestions")

    if approve or reject:
        edits = {
            "suggested_title": title,
            "suggested_summary": summary,
            "suggested_tags": [t.strip() for t in tags.split(",") if t.strip()],
            "human_approved": approve,
        }
        if feedback.strip():
            edits["human_feedback"] = feedback.strip()

        try:
            with st.spinner("Running Reviewer/Critic and generating the final report..."):
                result = resume_pipeline(
                    st.session_state.app, st.session_state.config, edits=edits
                )
        except Exception as exc:  # noqa: BLE001
            logger.exception("Pipeline failed to resume")
            st.error(f"Something went wrong generating the report: {exc}")
            return

        st.session_state.result = result
        st.session_state.stage = "done"
        st.rerun()


def _render_done_stage() -> None:
    st.title("Publication Assistant")
    result = st.session_state.result

    if result.get("errors"):
        with st.expander("Warnings encountered during the run", expanded=False):
            for err in result["errors"]:
                st.write(f"- {err}")

    report = result.get("final_report", "(no report generated)")
    st.markdown(report)

    owner = result.get("owner") or "unknown"
    repo = result.get("repo") or "report"
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    filename = f"{owner}_{repo}_{timestamp}.md"

    st.download_button(
        "Download report (.md)",
        data=report,
        file_name=filename,
        mime="text/markdown",
    )

    if st.button("Analyze another repository"):
        _reset()
        st.rerun()


def main() -> None:
    _init_session_state()
    _render_sidebar()

    stage = st.session_state.stage
    if stage == "input":
        _render_input_stage()
    elif stage == "review":
        _render_review_stage()
    elif stage == "done":
        _render_done_stage()
    else:
        _reset()
        st.rerun()


if __name__ == "__main__":
    main()