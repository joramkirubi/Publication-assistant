#!/usr/bin/env python3
"""
CLI entry point for the Publication Assistant multi-agent system.

Usage:
    python main.py --repo https://github.com/owner/repo
    python main.py --repo https://github.com/owner/repo --output report.md
    python main.py --repo https://github.com/owner/repo --no-save
"""
import argparse
import logging
import re
import sys
from datetime import datetime
from pathlib import Path

from src.graph import run_pipeline

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
    args = parser.parse_args()

    print(f"\nAnalyzing {args.repo} ...\n")
    result = run_pipeline(repo_url=args.repo, user_description=args.description)

    if result.get("errors"):
        print("⚠️  Warnings/errors encountered during the run:")
        for err in result["errors"]:
            print(f"  - {err}")
        print()

    report = result.get("final_report", "(no report generated)")
    print(report)

    if args.no_save:
        return 0

    output_path = Path(args.output) if args.output else _default_report_path(result, args.repo)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(f"\n✅ Report saved to {output_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())