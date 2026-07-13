"""
Regression test for the CLI review checkpoint's input validation.

Originally, any input other than "e" or "n" (e.g. a stray "1") was silently
treated as approval, since the code only special-cased those two values.
This proves invalid input is now rejected and re-prompted instead.
"""
from unittest.mock import patch

import main


def test_invalid_input_is_rejected_and_reprompted():
    with patch("builtins.input") as mock_input:
        # "1" is invalid and should trigger a re-prompt; "n" is then valid.
        # Third input() call is the feedback prompt (skipped with "").
        mock_input.side_effect = ["1", "n", ""]
        result = main._human_review_checkpoint(
            {"suggested_title": "X", "suggested_summary": "Y", "suggested_tags": ["A", "B"]}
        )
        assert mock_input.call_count == 3
        assert result["human_approved"] is False


def test_valid_input_on_first_try_does_not_reprompt():
    with patch("builtins.input") as mock_input:
        mock_input.side_effect = ["y", ""]  # valid immediately, then skip feedback
        result = main._human_review_checkpoint(
            {"suggested_title": "X", "suggested_summary": "Y", "suggested_tags": ["A"]}
        )
        assert mock_input.call_count == 2
        assert result["human_approved"] is True


def test_empty_input_defaults_to_approve():
    with patch("builtins.input") as mock_input:
        mock_input.side_effect = ["", ""]  # Enter = default approve, skip feedback
        result = main._human_review_checkpoint(
            {"suggested_title": "X", "suggested_summary": "Y", "suggested_tags": ["A"]}
        )
        assert result["human_approved"] is True