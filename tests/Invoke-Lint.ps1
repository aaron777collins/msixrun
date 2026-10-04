# PSScriptAnalyzer over msixrun.ps1 (strict, incl. 5.1/7.0 syntax compatibility)
# and over the tests (without the rules that fight Pester stubs). Exits nonzero
# if anything is reported.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$main  = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'msixrun.ps1') -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
$tests = @(Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1') `
    -ExcludeRule PSReviewUnusedParameter, PSUseShouldProcessForStateChangingFunctions, PSUseDeclaredVarsMoreThanAssignments)
$all = $main + $tests
$all | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
Write-Host ("PSScriptAnalyzer findings: {0} (msixrun.ps1: {1}, tests: {2})" -f $all.Count, $main.Count, $tests.Count)
if ($all.Count -gt 0) { exit 1 }
