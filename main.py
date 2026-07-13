#!/usr/bin/env python3
"""
CLI entry point for the Publication Assistant multi-agent system.

Usage:
    python main.py --repo https://github.com/owner/repo
    python main.py --repo https://github.com/owner/repo --output report.md
    python main.py --repo https://github.com/owner/repo --no-save
    python main.py --repo https://github.com/owner/repo --auto-approve
"""
import argparse
import logging
import re
import sys
from datetime import datetime
from pathlib import Path

from src.graph import resume_pipeline, start_pipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")

REPORTS_DIR = Path("reports")


def _default_report_path(result: dict, repo_url: str) -> Path:
    """
    Build a timestamped report path under reports/, e.g.
    reports/joramkirubi_medical-rag-assistant_20260702-143012.md
    Falls back to sanitizing the raw URL if the pipeline failed before it
    could extract owner/repo (so a report still gets saved either way).
    """
    owner = result.get("owner") or ""
    repo = result.get("repo") or ""
    if not (owner and repo):
        slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", repo_url.rstrip("/").split("/")[-1]) or "report"
        owner, repo = "unknown", slug
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return REPORTS_DIR / f"{owner}_{repo}_{timestamp}.md"


def _human_review_checkpoint(paused_state: dict) -> dict:
    """
    Presents the suggested tags/title/summary to the person running the
    tool, before Reviewer/Critic locks them into the final report. Returns
    a dict of edits to apply to state (possibly empty) via update_state().

    This is the human-in-the-loop checkpoint: the graph is genuinely
    paused here (via LangGraph's interrupt_before), not just printing a
    status message.
    """
    print("── Human Review Checkpoint ──────────────────────────────")
    print(f"Suggested title:   {paused_state.get('suggested_title') or '(none)'}")
    print(f"Suggested summary: {paused_state.get('suggested_summary') or '(none)'}")
    tags = paused_state.get("suggested_tags") or []
    print(f"Suggested tags:    {', '.join(tags) if tags else '(none)'}")
    print()

    while True:
        answer = input("Approve as-is? [Y/n/e=edit]: ").strip().lower()
        if answer in ("", "y", "n", "e"):
            break
        print(f"  '{answer}' isn't a valid choice — please type Y, n, or e.")

    edits: dict = {}

    if answer == "e":
        new_title = input(f"New title (Enter to keep current): ").strip()
        new_summary = input(f"New summary (Enter to keep current): ").strip()
        new_tags = input(f"New tags, comma-separated (Enter to keep current): ").strip()
        if new_title:
            edits["suggested_title"] = new_title
        if new_summary:
            edits["suggested_summary"] = new_summary
        if new_tags:
            edits["suggested_tags"] = [t.strip() for t in new_tags.split(",") if t.strip()]

    feedback = input("Any feedback on these suggestions? (optional, Enter to skip): ").strip()
    if feedback:
        edits["human_feedback"] = feedback

    edits["human_approved"] = answer != "n"
    return edits


def main() -> int:
    parser = argparse.ArgumentParser(description="Publication Assistant for AI Projects")
    parser.add_argument("--repo", required=True, help="GitHub repo URL, e.g. https://github.com/owner/repo")
    parser.add_argument("--description", default=None, help="Optional short project description")
    parser.add_argument(
        "--output",
        default=None,
        help="Optional path to save the final report. If omitted, the report is "
        "still auto-saved under reports/<owner>_<repo>_<timestamp>.md",
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Skip auto-saving the report to disk; just print it.",
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        help="Skip the interactive human review checkpoint and approve suggestions as-is "
        "(useful for scripting/CI; no --no-save equivalent needed, saving still happens).",
    )
    args = parser.parse_args()

    print(f"\nAnalyzing {args.repo} ...\n")
    app, config, paused_state = start_pipeline(args.repo, args.description)

    if paused_state.get("errors"):
        print("⚠️  Warnings/errors encountered so far:")
        for err in paused_state["errors"]:
            print(f"  - {err}")
        print()

    if args.auto_approve:
        edits = {"human_approved": True}
    else:
        edits = _human_review_checkpoint(paused_state)

    result = resume_pipeline(app, config, edits=edits)

    if result.get("errors"):
        print("\n⚠️  Warnings/errors encountered during the run:")
        for err in result["errors"]:
            print(f"  - {err}")
        print()

    report = result.get("final_report", "(no report generated)")
    print("\n" + report)

    if args.no_save:
        return 0

    output_path = Path(args.output) if args.output else _default_report_path(result, args.repo)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(f"\n✅ Report saved to {output_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
