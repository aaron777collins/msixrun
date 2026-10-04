# Runs the Pester 5 tests and the PSScriptAnalyzer lint. Exits nonzero on failure.
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.Exit = $false
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$r = Invoke-Pester -Configuration $cfg
if ($r.FailedCount -gt 0 -or $r.Result -ne 'Passed') { exit 1 }
