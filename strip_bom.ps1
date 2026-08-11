#Requires -Version 5.1
<#
.SYNOPSIS
  Strips UTF-8 byte-order-marks (BOM) that Set-Content -Encoding UTF8 added
  to every file written by previous patch scripts in this project.
.DESCRIPTION
  Run this from the ROOT of your Publication-assistant repo (same folder as
  main.py). Windows PowerShell 5.1's "Set-Content -Encoding UTF8" always
  writes a 3-byte BOM at the start of the file -- there is no flag to turn
  this off in PS 5.1 (only PowerShell 7+ has a separate UTF8NoBOM option).
  Every file any prior patch script wrote likely has this invisible BOM,
  which is harmless to Python's normal "import"/"streamlit run" path (it
  auto-strips BOMs) but breaks tools that read the file as plain text,
  such as "python -c \"ast.parse(open('app.py').read())\"" in CI.

  This script scans every text file in the repo (excluding .git, .venv,
  __pycache__) and removes a leading BOM if one is present. It does not
  touch files that don't have one.
#>

$ErrorActionPreference = "Stop"
Write-Host "Scanning repo for UTF-8 BOM markers..." -ForegroundColor Cyan

$excludeDirs = @(".git", ".venv", "__pycache__", ".pytest_cache")
$bomBytes = [byte[]](0xEF, 0xBB, 0xBF)

$allFiles = Get-ChildItem -Path . -Recurse -File -Force | Where-Object {
    $relative = $_.FullName.Substring((Get-Location).Path.Length + 1)
    $parts = $relative -split '[\\/]'
    -not ($parts | Where-Object { $excludeDirs -contains $_ })
}

$fixedCount = 0
foreach ($file in $allFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq $bomBytes[0] -and $bytes[1] -eq $bomBytes[1] -and $bytes[2] -eq $bomBytes[2]) {
        $newBytes = New-Object byte[] ($bytes.Length - 3)
        [System.Array]::Copy($bytes, 3, $newBytes, 0, $bytes.Length - 3)
        [System.IO.File]::WriteAllBytes($file.FullName, $newBytes)
        Write-Host "  stripped BOM: $($file.FullName.Substring((Get-Location).Path.Length + 1))"
        $fixedCount++
    }
}

Write-Host ""
if ($fixedCount -eq 0) {
    Write-Host "No BOMs found. Nothing to fix." -ForegroundColor Yellow
} else {
    Write-Host "Fixed $fixedCount file(s)." -ForegroundColor Green
}
Write-Host ""
Write-Host "Verify with:" -ForegroundColor Green
Write-Host "  python -c `"import ast; ast.parse(open('app.py').read())`""
Write-Host "  pytest tests/ --cov=src --cov-report=term-missing"
Write-Host ""
Write-Host "Then commit and push:"
Write-Host "  git add ."
Write-Host "  git commit -m `"Strip UTF-8 BOM markers left by Set-Content -Encoding UTF8`""
Write-Host "  git push"
