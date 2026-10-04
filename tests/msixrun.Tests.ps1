#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pester 5 tests for msixrun.ps1. Everything that touches Windows is mocked, so
# these run on macOS and Linux too. Run: pwsh -File tests/Invoke-Tests.ps1

BeforeAll {
    # Stubs for Windows-only commands, so they exist (with real parameter
    # names) to be mocked on macOS and Linux. On Windows the real ones are used.
    $stubs = @{
        'Add-AppxPackage'          = { param($Path, [switch]$AllowUnsigned) }
        'Remove-AppxPackage'       = { param($Package) }
        'Get-AppxPackage'          = { param($Name) }
        'Get-AppxPackageManifest'  = { param($Package) }
        'Get-AuthenticodeSignature' = { param($FilePath) }
        'Export-Certificate'       = { param($Cert, $FilePath, $Type) }
        'Import-Certificate'       = { param($FilePath, $CertStoreLocation) }
    }
    foreach ($n in $stubs.Keys) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:script:$n" -Value $stubs[$n]
        }
    }
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $script:Repo 'msixrun.ps1'
    . $script:ScriptPath

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('msixrun-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Work | Out-Null

    function New-TestMsix {
        param([string]$Dir, [string]$FileName = 'app.msix', [string]$Name = 'Acme.App', [string]$Publisher = 'CN=Acme', [switch]$Bundle)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $path = Join-Path $Dir $FileName
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
        try {
            if ($Bundle) {
                $entry = $zip.CreateEntry('AppxMetadata/AppxBundleManifest.xml')
                $xml = "<Bundle xmlns='http://schemas.microsoft.com/appx/2013/bundle'><Identity Name='$Name' Publisher='$Publisher' Version='1.0.0.0'/></Bundle>"
            } else {
                $entry = $zip.CreateEntry('AppxManifest.xml')
                $xml = "<Package xmlns='http://schemas.microsoft.com/appx/manifest/foundation/windows10'><Identity Name='$Name' Publisher='$Publisher' Version='1.0.0.0'/></Package>"
            }
            $w = New-Object IO.StreamWriter($entry.Open())
            $w.Write($xml); $w.Dispose()
        } finally { $zip.Dispose() }
        return $path
    }

    # A real certificate object: Export-Certificate's -Cert parameter is typed,
    # so a fake object only works for the stubs on macOS, not for the real
    # cmdlet on Windows.
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $req = New-Object Security.Cryptography.X509Certificates.CertificateRequest 'CN=Acme Ltd, O=Acme', $rsa,
        ([Security.Cryptography.HashAlgorithmName]::SHA256), ([Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $script:TestCert = $req.CreateSelfSigned([DateTimeOffset]'2029-01-01T12:00:00Z', [DateTimeOffset]'2030-01-02T12:00:00Z')

    function Get-LogText { $script:Log -join "`n" }
    function Get-ElevatedCommand { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:ElevatedArgs[4])) }
    function HResultOf([string]$hex) { [BitConverter]::ToInt32([BitConverter]::GetBytes([Convert]::ToUInt32($hex, 16)), 0) }
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'msixrun.ps1' {
    BeforeEach {
        $script:Log = New-Object System.Collections.Generic.List[string]
        $script:InstallResults = @()      # per Add-AppxPackage call: $null = success, string/exception = throw
        $script:InstallCalls = 0
        $script:InstallArgs = @()
        $script:Installed = @()           # what Get-AppxPackage knows about
        $script:Removed = @()
        $script:Answers = New-Object System.Collections.Queue
        $script:Prompts = New-Object System.Collections.Generic.List[string]
        $script:Interactive = $true
        $script:DevMode = $true
        $script:CanUnsigned = $true
        $script:Signer = $script:TestCert
        $script:HasSignature = $true
        $script:ElevatedExit = 0
        $script:ElevatedThrow = $null
        $script:InStore = $true
        $script:ElevatedArgs = $null
        $script:Exported = $null
        $script:Launched = $null
        $script:Pkg = New-TestMsix -Dir (Join-Path $script:Work ([guid]::NewGuid().ToString('N')))

        Mock Write-Host { $script:Log.Add([string]$Object) }
        Mock Test-Interactive { $script:Interactive }
        Mock Read-Answer { $script:Prompts.Add($Prompt); if ($script:Answers.Count) { [string]$script:Answers.Dequeue() } else { '' } }
        Mock Test-DeveloperMode { $script:DevMode }
        Mock Test-AllowUnsignedSupported { $script:CanUnsigned }
        Mock Add-AppxPackage {
            $script:InstallArgs += , @{ Path = $Path; AllowUnsigned = [bool]$AllowUnsigned }
            $r = if ($script:InstallCalls -lt $script:InstallResults.Count) { $script:InstallResults[$script:InstallCalls] } else { $null }
            $script:InstallCalls++
            if ($r) { throw $r }
            $script:Installed = @($script:Installed) + [pscustomobject]@{
                Name = 'Acme.App'; Publisher = 'CN=Acme'; Version = '1.0.0.0'
                PackageFullName = 'Acme.App_1.0.0.0_x64__8wekyb3d8bbwe'; PackageFamilyName = 'Acme.App_8wekyb3d8bbwe' }
        }
        Mock Get-AppxPackage { @($script:Installed | Where-Object { @($Name) -contains $_.Name }) }
        Mock Get-AppxPackageManifest { [pscustomobject]@{ Package = [pscustomobject]@{ Applications = [pscustomobject]@{ Application = @([pscustomobject]@{ Id = 'App' }) } } } }
        Mock Remove-AppxPackage {
            $script:Removed += $Package
            $script:Installed = @($script:Installed | Where-Object { $_.PackageFullName -ne $Package })
        }
        Mock Get-AuthenticodeSignature {
            if ($script:HasSignature) { [pscustomobject]@{ Status = 'UnknownError'; SignerCertificate = $script:Signer } }
            else { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        }
        Mock Export-Certificate { Set-Content -LiteralPath $FilePath -Value 'cer'; $script:Exported = $FilePath }
        Mock Start-Process {
            $script:ElevatedArgs = $ArgumentList
            if ($script:ElevatedThrow) { throw $script:ElevatedThrow }
            [pscustomobject]@{ ExitCode = $script:ElevatedExit }
        } -ParameterFilter { $FilePath -eq 'powershell.exe' }
        Mock Start-Process { $script:Launched = $ArgumentList } -ParameterFilter { $FilePath -eq 'explorer.exe' }
        Mock Test-Path { $script:InStore } -ParameterFilter { $LiteralPath -like 'Cert:*' }
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:Pkg -Destination $OutFile; $script:Downloaded = $Uri }
    }

    Context 'happy path' {
        It 'installs a local file and launches PFN!AppId' {
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 0
            Get-LogText | Should -Match 'Package: Acme.App'
            $script:InstallArgs[0].Path | Should -Be $script:Pkg
            $script:InstallArgs[0].AllowUnsigned | Should -BeFalse
            $script:Launched | Should -Be 'shell:AppsFolder\Acme.App_8wekyb3d8bbwe!App'
            Should -Invoke Get-AuthenticodeSignature -Times 0 -Exactly
        }
        It '-NoLaunch installs only' {
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            Get-LogText | Should -Match 'Installed Acme.App.'
            $script:Launched | Should -BeNullOrEmpty
        }
        It 'reads the name from a bundle manifest' {
            $b = New-TestMsix -Dir (Join-Path $script:Work 'bundle') -FileName 'x.msixbundle' -Name 'Bundle.App' -Bundle
            (Get-MsixId -Path $b).Name | Should -Be 'Bundle.App'
            (Get-MsixId -Path $b).Publisher | Should -Be 'CN=Acme'
        }
        It 'uses the highest installed version when launching' {
            $script:Installed = @(
                [pscustomobject]@{ Name = 'Acme.App'; Publisher = 'CN=Acme'; Version = '0.9.0.0'; PackageFullName = 'old'; PackageFamilyName = 'Acme.App_old' })
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 0
            $script:Launched | Should -Be 'shell:AppsFolder\Acme.App_8wekyb3d8bbwe!App'
        }
        It 'fails clearly for a missing file' {
            (Invoke-Msixrun -Source (Join-Path $script:Work 'nope.msix') -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'file not found'
        }
        It 'fails clearly for a wrong extension' {
            $z = Join-Path $script:Work 'a.zip'; Set-Content -LiteralPath $z -Value 'x'
            (Invoke-Msixrun -Source $z -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'expected a .msix'
        }
        It 'accepts uppercase extensions' {
            $u = New-TestMsix -Dir (Join-Path $script:Work 'upper') -FileName 'APP.MSIX'
            (Invoke-Msixrun -Source $u -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
        }
        It 'reports an unreadable manifest' {
            $bad = Join-Path $script:Work 'bad.msix'; Set-Content -LiteralPath $bad -Value 'not a zip'
            (Invoke-Msixrun -Source $bad -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'could not read the package manifest'
        }
        It 'refuses a package name with unexpected characters' {
            $evil = New-TestMsix -Dir (Join-Path $script:Work 'evil') -Name 'Evil;calc'
            (Invoke-Msixrun -Source $evil -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'unexpected characters'
            Should -Invoke Add-AppxPackage -Times 0 -Exactly
        }
        It 'shows Windows'' message for an unrelated failure and does nothing else' {
            $script:InstallResults = @('Deployment failed with HRESULT: 0x80070005, Access is denied.')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'install failed: .*0x80070005'
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Remove-AppxPackage -Times 0 -Exactly
        }
        It 'copies a path containing wildcard characters before installing' {
            $dir = Join-Path $script:Work 'wild'
            $w = New-TestMsix -Dir $dir -FileName 'app[1].msix'
            (Invoke-Msixrun -Source $w -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:InstallArgs[0].Path | Should -Not -Match '[\[\]]'
            $script:InstallArgs[0].Path | Should -Not -Be $w
        }
    }

    Context 'URL source' {
        It 'downloads with -UseBasicParsing, forces TLS 1.2, installs, and cleans up' {
            (Invoke-Msixrun -Source 'https://example.com/dl/App_1.0.msix?token=abc' -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $UseBasicParsing -and $Uri -eq 'https://example.com/dl/App_1.0.msix?token=abc' }
            $script:InstallArgs[0].Path | Should -Match 'App_1\.0\.msix$'
            ([Net.ServicePointManager]::SecurityProtocol -band [Net.SecurityProtocolType]::Tls12) | Should -Not -Be 0
            Test-Path -LiteralPath $script:InstallArgs[0].Path | Should -BeFalse
        }
        It 'names the file download.msix when the URL has no package extension' {
            (Invoke-Msixrun -Source 'http://example.com/latest' -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:InstallArgs[0].Path | Should -Match 'download\.msix$'
        }
        It 'sanitizes hostile characters in the file name' {
            (Invoke-Msixrun -Source 'https://example.com/a%20b$(x).msix' -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            (Split-Path -Leaf $script:InstallArgs[0].Path) | Should -Match '^[A-Za-z0-9._-]+$'
        }
        It 'reports a failed download and cleans up' {
            Mock Invoke-WebRequest { throw 'The remote server returned an error: (404) Not Found.' }
            (Invoke-Msixrun -Source 'https://example.com/a.msix' -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'download failed'
            Should -Invoke Add-AppxPackage -Times 0 -Exactly
        }
    }

    Context 'untrusted publisher' {
        BeforeEach { $script:Untrusted = 'Deployment failed with HRESULT: 0x800B0109, The root certificate of the signature in the app package or bundle must be trusted.' }

        It 'asks, exports THIS signer, imports to TrustedPeople in one elevated child, verifies, retries once' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 0
            $script:Prompts[0] | Should -Be 'Windows does not trust the publisher of this package. Trust CN=Acme Ltd, O=Acme and install? [y/N]'
            Get-LogText | Should -Match 'Signer:\s+CN=Acme Ltd, O=Acme'
            Get-LogText | Should -Match ('Thumbprint:\s+' + $script:TestCert.Thumbprint + ' \(SHA-1\)')
            Get-LogText | Should -Match ('Valid until: ' + $script:TestCert.NotAfter.ToString('yyyy-MM-dd'))
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'powershell.exe' -and $Verb -eq 'RunAs' -and $Wait -and $PassThru }
            $script:ElevatedArgs[3] | Should -Be '-EncodedCommand'
            $inner = Get-ElevatedCommand
            $inner | Should -Match 'Import-Certificate'
            $inner | Should -Match 'Cert:\\LocalMachine\\TrustedPeople'
            $inner | Should -Not -Match 'Root'
            $inner | Should -Match ([regex]::Escape($script:Exported))
            Test-Path -LiteralPath $script:Exported | Should -BeFalse
            $script:InstallCalls | Should -Be 2
            Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq ('Cert:\LocalMachine\TrustedPeople\' + $script:TestCert.Thumbprint) }
        }
        It 'does nothing when the answer is n' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:Answers.Enqueue('n')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'you chose not to trust'
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Export-Certificate -Times 0 -Exactly
            $script:InstallCalls | Should -Be 1
        }
        It 'treats an empty answer as no' {
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Should -Invoke Start-Process -Times 0 -Exactly
        }
        It 'accepts "yes"' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:Answers.Enqueue('yes')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
        }
        It 'non-interactive without a switch fails and names -Trust' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match '-Trust'
            Should -Invoke Start-Process -Times 0 -Exactly
            $script:Prompts.Count | Should -Be 0
        }
        It '-Trust skips the prompt' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            $script:Prompts.Count | Should -Be 0
            Get-LogText | Should -Match '\(-Trust\)'
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'powershell.exe' }
        }
        It '-Yes skips the prompt' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 0
            Get-LogText | Should -Match '\(-Yes\)'
        }
        It 'recognizes <code>' -ForEach @(
            @{ code = '0x800B010A' }, @{ code = '0x800B0112' }, @{ code = '0x800B0004' }) {
            $script:InstallResults = @("Deployment failed with HRESULT: $code", $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'powershell.exe' }
        }
        It 'recognizes the code from the exception HResult alone' {
            $ex = New-Object System.Runtime.InteropServices.COMException 'Deployment failed', (HResultOf '800B0109')
            $script:InstallResults = @($ex, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'powershell.exe' }
        }
        It 'recognizes the code from the message text alone' {
            $script:InstallResults = @('The root certificate of the signature in the app package must be trusted', $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
        }
        It 'reports clearly when UAC is declined (Win32Exception 1223) and does not retry' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:ElevatedThrow = New-Object System.ComponentModel.Win32Exception 1223
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'permission was declined'
            Get-LogText | Should -Match 'Nothing was changed'
            $script:InstallCalls | Should -Be 1
            Test-Path -LiteralPath $script:Exported | Should -BeFalse
        }
        It 'reports UAC declined when wrapped in an InvalidOperationException (Windows PowerShell 5.1)' {
            $script:InstallResults = @($script:Untrusted, $null)
            $inner = New-Object System.ComponentModel.Win32Exception 1223
            $script:ElevatedThrow = New-Object System.InvalidOperationException 'This command cannot be run due to the error: The operation was canceled by the user.', $inner
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'permission was declined'
        }
        It 'checks the elevated child''s exit code' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:ElevatedExit = 1
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'exited with code 1'
            $script:InstallCalls | Should -Be 1
        }
        It 'fails when the thumbprint is not in TrustedPeople afterwards' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:InStore = $false
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'not in Trusted People'
            $script:InstallCalls | Should -Be 1
        }
        It 'fails when the package has no signer certificate' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:HasSignature = $false
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'could not read the signer certificate'
            Should -Invoke Start-Process -Times 0 -Exactly
        }
        It 'does not loop when the retry fails again' {
            $script:InstallResults = @($script:Untrusted, $script:Untrusted, $script:Untrusted)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $true -Yes $false) | Should -Be 1
            $script:InstallCalls | Should -Be 2
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'powershell.exe' }
            Get-LogText | Should -Match 'install failed'
        }
        It 'quotes the temp path safely inside the elevated command' {
            ConvertTo-PsQuoted "a'b$([char]0x2019)c" | Should -Be "a''b$([char]0x2019)$([char]0x2019)c"
        }
    }

    Context 'unsigned package' {
        BeforeEach { $script:Unsigned = 'Deployment failed with HRESULT: 0x800B0100, App package must be digitally signed' }

        It 'with Developer Mode on and the user saying y retries with -AllowUnsigned' {
            $script:InstallResults = @($script:Unsigned, $null)
            $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:Prompts[0] | Should -Match 'This package is not signed'
            $script:InstallArgs[0].AllowUnsigned | Should -BeFalse
            $script:InstallArgs[1].AllowUnsigned | Should -BeTrue
        }
        It 'declining leaves it uninstalled' {
            $script:InstallResults = @($script:Unsigned, $null)
            $script:Answers.Enqueue('n')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 1
            $script:InstallCalls | Should -Be 1
        }
        It 'non-interactive without -Yes names -Yes' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Unsigned, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match '-Yes'
            $script:InstallCalls | Should -Be 1
        }
        It '-Trust alone does not allow unsigned installs' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Unsigned, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 1
            $script:InstallCalls | Should -Be 1
        }
        It '-Yes retries with -AllowUnsigned' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Unsigned, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 0
            $script:InstallArgs[1].AllowUnsigned | Should -BeTrue
        }
        It 'with Developer Mode off explains how to turn it on' {
            $script:DevMode = $false
            $script:InstallResults = @($script:Unsigned, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 1
            Get-LogText | Should -Match 'Developer Mode is off'
            Get-LogText | Should -Match 'Windows 11: Settings > System > For developers'
            Get-LogText | Should -Match 'Windows 10: Settings > Update & Security > For developers'
            $script:InstallCalls | Should -Be 1
        }
        It 'with Developer Mode on but no -AllowUnsigned says so' {
            $script:CanUnsigned = $false
            $script:InstallResults = @($script:Unsigned, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 1
            Get-LogText | Should -Match 'cannot install unsigned'
            $script:InstallCalls | Should -Be 1
        }
        It 'does not loop when the unsigned retry fails again' {
            $script:InstallResults = @($script:Unsigned, $script:Unsigned)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 1
            $script:InstallCalls | Should -Be 2
        }
    }

    Context 'same package from a different publisher' {
        BeforeEach {
            $script:Conflict = 'Deployment failed with HRESULT: 0x80073CFB, The provided package is already installed'
            $script:Installed = @([pscustomobject]@{ Name = 'Acme.App'; Publisher = 'CN=Old Publisher'; Version = '0.5.0.0'
                PackageFullName = 'Acme.App_0.5.0.0_x64__oldhash'; PackageFamilyName = 'Acme.App_oldhash' })
        }
        It 'asks, removes the old one, and retries' -ForEach @(
            @{ code = '0x80073CFB' }, @{ code = '0x80073CF3' }, @{ code = '0x80073D06' }) {
            $script:InstallResults = @("Deployment failed with HRESULT: $code", $null)
            $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:Prompts[0] | Should -Be 'An older Acme.App from a different publisher is installed. Remove it and install this one? Its local data will be removed. [y/N]'
            $script:Removed | Should -Be @('Acme.App_0.5.0.0_x64__oldhash')
            $script:InstallCalls | Should -Be 2
        }
        It 'keeps the old one when the answer is n' {
            $script:InstallResults = @($script:Conflict, $null)
            $script:Answers.Enqueue('n')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 1
            $script:Removed.Count | Should -Be 0
            Get-LogText | Should -Match 'chose to keep the older Acme.App'
        }
        It 'non-interactive without -Yes names -Yes' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Conflict, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match '-Yes'
            $script:Removed.Count | Should -Be 0
        }
        It '-Trust alone never removes local data' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Conflict, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 1
            $script:Removed.Count | Should -Be 0
        }
        It '-Yes removes without asking' {
            $script:Interactive = $false
            $script:InstallResults = @($script:Conflict, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 0
            $script:Removed.Count | Should -Be 1
        }
        It 'leaves a same-publisher copy alone' {
            $script:Installed = @([pscustomobject]@{ Name = 'Acme.App'; Publisher = 'CN=Acme'; Version = '0.5.0.0'; PackageFullName = 'same'; PackageFamilyName = 'x' })
            $script:InstallResults = @($script:Conflict)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 1
            $script:Removed.Count | Should -Be 0
            Get-LogText | Should -Match 'install failed'
        }
        It 'reports a failed removal' {
            Mock Remove-AppxPackage { throw 'The package is in use' }
            $script:InstallResults = @($script:Conflict, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $true) | Should -Be 1
            Get-LogText | Should -Match 'could not remove the older Acme.App: The package is in use'
            $script:InstallCalls | Should -Be 1
        }
        It 'fixes an untrusted publisher first, then the older copy' {
            $script:InstallResults = @('0x800B0109', $script:Conflict, $null)
            $script:Answers.Enqueue('y'); $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:InstallCalls | Should -Be 3
            $script:Removed.Count | Should -Be 1
        }
    }

    Context 'entry point' {
        BeforeAll {
            $script:Pwsh = (Get-Process -Id $PID).Path
            $script:Missing = Join-Path $script:Work 'missing.msix'
        }
        It 'prints the version from a saved file and exits 0' {
            $o = & $script:Pwsh -NoProfile -File $script:ScriptPath -Version
            $LASTEXITCODE | Should -Be 0
            "$o" | Should -Match 'msixrun 1\.1\.0'
        }
        It 'prints usage and exits 1 with no arguments' {
            $o = & $script:Pwsh -NoProfile -File $script:ScriptPath
            $LASTEXITCODE | Should -Be 1
            "$o" | Should -Match 'Usage:'
        }
        It 'exits 1 from a saved file when the package is missing' {
            $null = & $script:Pwsh -NoProfile -File $script:ScriptPath $script:Missing
            $LASTEXITCODE | Should -Be 1
        }
        It 'in scriptblock mode never exits the host and sets LASTEXITCODE' {
            $cmd = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$($script:ScriptPath)'))) '$($script:Missing)' -NoLaunch -Trust -Yes; 'alive:' + `$LASTEXITCODE"
            $o = & $script:Pwsh -NoProfile -Command $cmd
            "$o" | Should -Match 'alive:1'
        }
        It 'in scriptblock mode -Version leaves the host open with LASTEXITCODE 0' {
            $cmd = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$($script:ScriptPath)'))) -Version; 'alive:' + `$LASTEXITCODE"
            $o = & $script:Pwsh -NoProfile -Command $cmd
            "$o" | Should -Match 'alive:0'
        }
    }

    Context 'Windows PowerShell 5.1 compatibility' {
        It 'is pure ASCII (5.1 reads BOM-less files as ANSI)' {
            $bytes = [IO.File]::ReadAllBytes($script:ScriptPath)
            ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
        It 'has the param block before any other code' {
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errs)
            $errs.Count | Should -Be 0
            $ast.ParamBlock | Should -Not -BeNullOrEmpty
            $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'NoLaunch'
            $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'Trust'
            $ast.ParamBlock.Parameters.Name.VariablePath.UserPath | Should -Contain 'Yes'
        }
        It 'does not call exit inside any function' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
            $exits = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
            foreach ($e in $exits) {
                $inFunction = $false; $p = $e.Parent
                while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true }; $p = $p.Parent }
                $inFunction | Should -BeFalse
            }
        }
    }
}

Describe 'msixrun.ps1 helpers' {
    It 'Test-UacDeclined is true for 1223 and "canceled by the user", false otherwise' {
        Test-UacDeclined (New-Object System.ComponentModel.Win32Exception 1223) | Should -BeTrue
        Test-UacDeclined (New-Object System.Exception 'The operation was cancelled by the user.') | Should -BeTrue
        Test-UacDeclined (New-Object System.ComponentModel.Win32Exception 5) | Should -BeFalse
    }
    It 'Test-DeveloperMode is true when AllowDevelopmentWithoutDevLicense is 1' {
        Mock Get-ItemProperty { [pscustomobject]@{ AllowDevelopmentWithoutDevLicense = 1 } }
        Test-DeveloperMode | Should -BeTrue
        Should -Invoke Get-ItemProperty -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' }
    }
    It 'Test-DeveloperMode is false when the value is 0' {
        Mock Get-ItemProperty { [pscustomobject]@{ AllowDevelopmentWithoutDevLicense = 0 } }
        Test-DeveloperMode | Should -BeFalse
    }
    It 'Test-DeveloperMode is false when the key is missing' {
        Mock Get-ItemProperty { throw 'key not found' }
        Test-DeveloperMode | Should -BeFalse
    }
    It 'Test-AllowUnsignedSupported follows the Add-AppxPackage parameter list' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{ AllowUnsigned = 1; Path = 1 } } }
        Test-AllowUnsignedSupported | Should -BeTrue
    }
    It 'Test-AllowUnsignedSupported is false when the parameter is absent' {
        Mock Get-Command { [pscustomobject]@{ Parameters = @{ Path = 1 } } }
        Test-AllowUnsignedSupported | Should -BeFalse
    }
    It 'Get-FailureText includes the HRESULT in hex' {
        $ex = New-Object System.Runtime.InteropServices.COMException 'boom', (HResultOf '800B0109')
        $text = try { throw $ex } catch { Get-FailureText $_ }
        $text | Should -Match '0x800B0109'
    }
}
