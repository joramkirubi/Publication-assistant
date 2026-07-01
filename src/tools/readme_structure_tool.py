"""
Tool: READMEStructureTool

A deterministic, rule-based checker that scans README markdown for the
presence of standard sections. This mirrors the "Essential" documentation
tier described in Ready Tensor's Open Source Repository Guide, so the
Reviewer agent has an objective, reproducible signal (not just an LLM's
opinion) about what's missing.
"""
import re

from langchain_core.tools import tool

# Each entry: canonical section name -> regex patterns that would satisfy it.
# Patterns are matched case-insensitively against markdown headings and,
# as a fallback, against bolded lines (some READMEs skip real headings).
ESSENTIAL_SECTIONS = {
    "Project Title": [r"^#\s+.+"],
    "Overview / Description": [r"##?\s*(overview|about|description)\b"],
    "Installation": [r"##?\s*(install|installation|setup|getting started)\b"],
    "Usage": [r"##?\s*(usage|how to use|quick ?start|example)"],
    "License": [r"##?\s*license\b", r"\blicense\b.{0,40}(mit|apache|gpl|bsd)"],
}

PROFESSIONAL_SECTIONS = {
    "Prerequisites": [r"##?\s*(prerequisites|requirements)\b"],
    "Configuration": [r"##?\s*(config|configuration)\b"],
    "Testing": [r"##?\s*(test|testing)\b"],
    "Contributing": [r"##?\s*contribut"],
}


def _section_present(readme_text: str, patterns: list[str]) -> bool:
    lines = readme_text.splitlines()
    for line in lines:
        for pattern in patterns:
            if re.search(pattern, line, flags=re.IGNORECASE):
                return True
    return False


@tool("readme_structure_checker")
def readme_structure_checker(readme_text: str) -> dict:
    """
    Check a README's markdown text against Ready Tensor's Essential and
    Professional documentation tiers and report which sections are present
    or missing.

    Args:
        readme_text: The full markdown text of the README file.

    Returns:
        A dict with 'essential' and 'professional' sub-dicts, each mapping
        section name -> bool (present or not), plus a 'score' summary.
    """
    essential_results = {
        name: _section_present(readme_text, patterns)
        for name, patterns in ESSENTIAL_SECTIONS.items()
    }
    professional_results = {
        name: _section_present(readme_text, patterns)
        for name, patterns in PROFESSIONAL_SECTIONS.items()
    }

    essential_met = sum(essential_results.values())
    essential_total = len(essential_results)

    return {
        "essential": essential_results,
        "professional": professional_results,
        "essential_score": f"{essential_met}/{essential_total}",
        "missing_essential": [k for k, v in essential_results.items() if not v],
        "missing_professional": [k for k, v in professional_results.items() if not v],
    }
