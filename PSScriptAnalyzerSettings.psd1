@{
    Severity     = @('Error', 'Warning', 'Information')
    IncludeRules = @('*')
    Rules        = @{
        # Must parse and run on Windows PowerShell 5.1 and PowerShell 7.
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
    ExcludeRules = @(
        # msixrun is an interactive installer: its output is for the person at
        # the keyboard, and Write-Host is what the tests capture.
        'PSAvoidUsingWriteHost'
    )
}
