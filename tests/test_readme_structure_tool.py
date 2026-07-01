from src.tools.readme_structure_tool import readme_structure_checker

GOOD_README = """
# My Cool Project

## Overview
This project does X.

## Installation
pip install my-cool-project

## Usage
Run `my-cool-project run`.

## License
MIT
"""

BAD_README = "Just a project. No structure here."


def test_good_readme_meets_all_essential_sections():
    result = readme_structure_checker.invoke({"readme_text": GOOD_README})
    assert result["essential_score"] == "5/5"
    assert result["missing_essential"] == []


def test_bad_readme_flags_missing_sections():
    result = readme_structure_checker.invoke({"readme_text": BAD_README})
    assert result["missing_essential"] != []
    assert "License" in result["missing_essential"]
    assert "Installation" in result["missing_essential"]


def test_empty_readme_is_all_missing():
    result = readme_structure_checker.invoke({"readme_text": ""})
    assert result["essential_score"] == "0/5"
