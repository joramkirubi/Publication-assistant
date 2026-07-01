#!/usr/bin/env python3
"""
CLI entry point for the Publication Assistant multi-agent system.

Usage:
    python main.py --repo https://github.com/owner/repo
    python main.py --repo https://github.com/owner/repo --output report.md
"""
import argparse
import logging
import sys

from src.graph import run_pipeline

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")


def main() -> int:
    parser = argparse.ArgumentParser(description="Publication Assistant for AI Projects")
    parser.add_argument("--repo", required=True, help="GitHub repo URL, e.g. https://github.com/owner/repo")
    parser.add_argument("--description", default=None, help="Optional short project description")
    parser.add_argument("--output", default=None, help="Optional path to save the final report as markdown")
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

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"\n✅ Report saved to {args.output}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
