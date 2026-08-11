#Requires -Version 5.1
<#
.SYNOPSIS
  Fixes the CI workflow so each Python version reports its own pass/fail
  instead of Actions cancelling 3.11/3.12 when 3.10 fails first.
.DESCRIPTION
  Run this from the ROOT of your Publication-assistant repo. Overwrites
  .github/workflows/tests.yml only.
#>

$ErrorActionPreference = "Stop"
Write-Host "Fixing CI matrix fail-fast behavior..." -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path ".github/workflows" | Out-Null

Write-Host "  writing .github/workflows/tests.yml"
$content = @'
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        python-version: ["3.10", "3.11", "3.12"]

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python ${{ matrix.python-version }}
        uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}

      - name: Install dependencies
        run: pip install -r requirements.txt

      - name: Run tests with coverage
        run: pytest tests/ --cov=src --cov-report=term-missing --cov-fail-under=70

      - name: Verify Streamlit app imports cleanly
        run: python -c "import ast; ast.parse(open('app.py').read())"
'@
Set-Content -Path ".github/workflows/tests.yml" -Value $content -Encoding UTF8 -NoNewline

Write-Host ""
Write-Host "Done. Commit and push, then check the Actions tab for the real 3.10 error." -ForegroundColor Green

