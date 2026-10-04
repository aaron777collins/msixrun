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
    }
    foreach ($n in $stubs.Keys) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:script:$n" -Value $stubs[$n]
        }
    }
    $script:RealTestPath = Get-Command Test-Path -CommandType Cmdlet   # before any mock hides it
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

    # Absolute paths only: a bare name is looked up in the current directory first.
    $script:PsExeRx = '^(?:[A-Za-z]:|/).*WindowsPowerShell.v1\.0.powershell\.exe$'
    $script:ExplorerRx = '^(?:[A-Za-z]:|/).*explorer\.exe$'

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
        Mock Start-Process {
            $script:ElevatedArgs = $ArgumentList
            $m = [regex]::Match((Get-ElevatedCommand), "\(,'([^']+)'\)")
            $script:CerPath = $m.Groups[1].Value
            $script:CerExistedAtStart = [IO.File]::Exists($script:CerPath)
            $script:CerBytesAtStart = if ($script:CerExistedAtStart) { [IO.File]::ReadAllBytes($script:CerPath) } else { $null }
            if ($script:ElevatedThrow) { throw $script:ElevatedThrow }
            [pscustomobject]@{ ExitCode = $script:ElevatedExit }
        } -ParameterFilter { $FilePath -match $script:PsExeRx }
        Mock Start-Process { $script:Launched = $ArgumentList } -ParameterFilter { $FilePath -match $script:ExplorerRx }
        # A default is required (Pester 6 rejects a filtered mock without one):
        # everything but the certificate store goes to the real cmdlet.
        Mock Test-Path {
            $real = @{}
            if ($null -ne $LiteralPath) { $real.LiteralPath = $LiteralPath } else { $real.Path = $Path }
            if ($PathType) { $real.PathType = $PathType }
            & $script:RealTestPath @real
        }
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
        It 'copies a path containing a backtick (the wildcard escape character) before installing' {
            $dir = Join-Path $script:Work 'tick'
            $w = New-TestMsix -Dir $dir -FileName 'app`1.msix'
            (Invoke-Msixrun -Source $w -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:InstallArgs[0].Path | Should -Not -Match '`'
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

        It 'asks, sends the .cer path and thumbprint of THIS signer to one elevated child, imports to TrustedPeople, verifies, retries once' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 0
            $script:Prompts[0] | Should -Be 'Windows does not trust the publisher of this package. Trust CN=Acme Ltd, O=Acme and install? [y/N]'
            Get-LogText | Should -Match 'Signer:\s+CN=Acme Ltd, O=Acme'
            Get-LogText | Should -Match ('Thumbprint:\s+' + $script:TestCert.Thumbprint + ' \(SHA-1\)')
            Get-LogText | Should -Match ('Valid until: ' + $script:TestCert.NotAfter.ToString('yyyy-MM-dd'))
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx -and $Verb -eq 'RunAs' -and $Wait -and $PassThru }
            $script:ElevatedArgs[3] | Should -Be '-EncodedCommand'
            $inner = Get-ElevatedCommand
            $inner | Should -Match 'X509Store'
            $inner | Should -Match "'TrustedPeople', 'LocalMachine'"
            $inner | Should -Not -Match "'Root'"   # not the base64 text, which is random
            $inner | Should -Not -Match 'Import-Certificate|Export-Certificate'
            # No certificate bytes on the command line: only the .cer path and the thumbprint.
            $inner | Should -Not -Match ([regex]::Escape([Convert]::ToBase64String($script:TestCert.RawData).Substring(0, 40)))
            $inner | Should -Not -Match 'FromBase64String'
            $inner | Should -Match ([regex]::Escape($script:TestCert.Thumbprint))
            $script:CerPath | Should -Match '\.cer$'
            $script:CerExistedAtStart | Should -BeTrue
            [Convert]::ToBase64String($script:CerBytesAtStart) | Should -Be ([Convert]::ToBase64String($script:TestCert.RawData))
            [IO.File]::Exists($script:CerPath) | Should -BeFalse   # removed afterwards
            $script:ElevatedArgs[4].Length | Should -BeLessThan 2048
            $script:InstallCalls | Should -Be 2
            Should -Invoke Test-Path -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq ('Cert:\LocalMachine\TrustedPeople\' + $script:TestCert.Thumbprint) }
        }
        It 'does nothing when the answer is n' {
            $script:InstallResults = @($script:Untrusted, $null)
            $script:Answers.Enqueue('n')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $false -Trust $false -Yes $false) | Should -Be 1
            Get-LogText | Should -Match 'you chose not to trust'
            Should -Invoke Start-Process -Times 0 -Exactly
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
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx }
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
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx }
        }
        It 'recognizes the code from the exception HResult alone' {
            $ex = New-Object System.Runtime.InteropServices.COMException 'Deployment failed', (HResultOf '800B0109')
            $script:InstallResults = @($ex, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx }
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
        It 'rejects a signature that is not merely untrusted: <status>' -ForEach @(
            @{ status = 'HashMismatch' }, @{ status = 'NotSigned' }, @{ status = 'Incompatible' }, @{ status = 'NotSupportedFileFormat' }) {
            $script:InstallResults = @($script:Untrusted, $null)
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = $status; SignerCertificate = $script:Signer } }
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            Get-LogText | Should -Match ('signature is not valid \(status: ' + $status + '\)')
            Should -Invoke Start-Process -Times 0 -Exactly
            $script:InstallCalls | Should -Be 1
        }
        It 'offers trust for status NotTrusted' {
            $script:InstallResults = @($script:Untrusted, $null)
            Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotTrusted'; SignerCertificate = $script:Signer } }
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx }
        }
        It 'the elevated verify step accepts the right thumbprint and refuses a different one, or a swapped file' {
            $pwsh = (Get-Process -Id $PID).Path
            $cer = Join-Path $script:Work 'verify.cer'
            [IO.File]::WriteAllBytes($cer, $script:TestCert.RawData)
            $run = {
                param($thumb, $file)
                $cmd = (Get-CertVerifyScript -CerPath $file -Thumbprint $thumb) + '} catch { exit 1 }'
                $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
                $null = & $pwsh -NoProfile -EncodedCommand $enc
                $LASTEXITCODE
            }
            (& $run $script:TestCert.Thumbprint $cer) | Should -Be 0
            (& $run ('0' * 40) $cer) | Should -Be 1
            # a different certificate in the file than the one the user was shown
            $other = (New-Object Security.Cryptography.X509Certificates.CertificateRequest 'CN=Other', ([Security.Cryptography.RSA]::Create(2048)),
                ([Security.Cryptography.HashAlgorithmName]::SHA256), ([Security.Cryptography.RSASignaturePadding]::Pkcs1)).CreateSelfSigned([DateTimeOffset]'2029-01-01T12:00:00Z', [DateTimeOffset]'2030-01-02T12:00:00Z')
            $swapped = Join-Path $script:Work 'swapped.cer'
            [IO.File]::WriteAllBytes($swapped, $other.RawData)
            (& $run $script:TestCert.Thumbprint $swapped) | Should -Be 1
            (& $run $script:TestCert.Thumbprint (Join-Path $script:Work 'missing.cer')) | Should -Be 1
        }
        It 'Get-CertVerifyScript refuses a thumbprint that is not 40 uppercase hex' -ForEach @(
            @{ t = 'abcd' }, @{ t = ('a' * 40) }, @{ t = ("A" * 39 + "'") }, @{ t = '' }) {
            { Get-CertVerifyScript -CerPath 'C:\x.cer' -Thumbprint $t } | Should -Throw
        }
        It 'the encoded elevated command stays well under 2 KB and holds only a path and a thumbprint' {
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            $script:ElevatedArgs[4].Length | Should -BeLessThan 2048
            (Get-ElevatedCommand).Length | Should -BeLessThan 900
        }
        It 'the user is shown the thumbprint that the elevated command carries' {
            $script:InstallResults = @($script:Untrusted, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $false) | Should -Be 0
            Get-LogText | Should -Match ('Thumbprint:\s+' + $script:TestCert.Thumbprint)
            Get-ElevatedCommand | Should -Match ("'" + $script:TestCert.Thumbprint + "'")
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
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -match $script:PsExeRx }
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
            @{ code = '0x80073CFB' }
            @{ code = '0x80073CF3, Windows cannot install the package because it conflicts with an installed package from a different publisher' }) {
            $script:InstallResults = @("Deployment failed with HRESULT: $code", $null)
            $script:Answers.Enqueue('y')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $false -Yes $false) | Should -Be 0
            $script:Prompts[0] | Should -Be 'An older Acme.App from a different publisher is installed. Remove it and install this one? Its local data will be removed. [y/N]'
            $script:Removed | Should -Be @('Acme.App_0.5.0.0_x64__oldhash')
            $script:InstallCalls | Should -Be 2
        }
        It 'never offers removal for a bare or dependency-only 0x80073CF3, even with -Yes' -ForEach @(
            @{ msg = 'Deployment failed with HRESULT: 0x80073CF3' }
            @{ msg = 'Deployment failed with HRESULT: 0x80073CF3, Package failed updates, dependency or conflict validation. Windows cannot install package Acme.App because this package depends on a framework that could not be found.' }) {
            $script:InstallResults = @($msg, $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            $script:Prompts.Count | Should -Be 0
            $script:Removed.Count | Should -Be 0
            @($script:Installed).Count | Should -Be 1
            Get-LogText | Should -Match 'install failed'
        }
        It 'never offers removal for an unfamiliar error, even when another publisher''s copy exists' -ForEach @(
            @{ code = '0x80073D06' }, @{ code = '0x80070070' }) {
            $script:InstallResults = @("Deployment failed with HRESULT: $code", $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            $script:Prompts.Count | Should -Be 0
            $script:Removed.Count | Should -Be 0
            Get-LogText | Should -Match 'install failed'
        }
        It 'does not remove anything when the retry after trusting fails for another reason' {
            $script:InstallResults = @('0x800B0109', 'Deployment failed with HRESULT: 0x80070070, disk full')
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            $script:Removed.Count | Should -Be 0
        }
        It 'a package named 0x80073CFB.msix failing for another reason never reaches removal, even with -Yes' {
            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $named = New-TestMsix -Dir $dir -FileName '0x80073CFB.msix'
            $script:InstallResults = @("Windows cannot open $named because the disk is full", $null)
            (Invoke-Msixrun -Source $named -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            $script:Prompts.Count | Should -Be 0
            $script:Removed.Count | Should -Be 0
            $script:InstallCalls | Should -Be 1
            Get-LogText | Should -Match 'install failed'
        }
        It 'a package named 0x80073CFB.msix with a real HRESULT for another failure never reaches removal' {
            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $named = New-TestMsix -Dir $dir -FileName '0x80073CFB.msix'
            $script:InstallResults = @("Deployment failed with HRESULT: 0x80070070, no room for $named", $null)
            (Invoke-Msixrun -Source $named -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            $script:Removed.Count | Should -Be 0
        }
        It 'a package named 0x80073CFB.msix with a genuine conflict is still removed on -Yes' {
            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $named = New-TestMsix -Dir $dir -FileName '0x80073CFB.msix'
            $script:InstallResults = @("Deployment failed with HRESULT: 0x80073CFB, conflict for $named", $null)
            (Invoke-Msixrun -Source $named -NoLaunch $true -Trust $true -Yes $true) | Should -Be 0
            $script:Removed.Count | Should -Be 1
        }
        It 'a package named like an untrusted code does not trigger the trust prompt' {
            $dir = Join-Path $script:Work ([guid]::NewGuid().ToString('N'))
            $named = New-TestMsix -Dir $dir -FileName '0x800B0109.msix'
            $script:InstallResults = @("cannot read $named", $null)
            (Invoke-Msixrun -Source $named -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            Should -Invoke Start-Process -Times 0 -Exactly
        }
        It 'a code in the message wins over wording from another failure' {
            $script:InstallResults = @('Deployment failed with HRESULT: 0x80070070, the package must be digitally signed but the disk is full', $null)
            (Invoke-Msixrun -Source $script:Pkg -NoLaunch $true -Trust $true -Yes $true) | Should -Be 1
            Should -Invoke Test-DeveloperMode -Times 0 -Exactly
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
        It 'in scriptblock mode inside another saved script does not exit that script' {
            $outer = Join-Path $script:Work 'outer.ps1'
            Set-Content -LiteralPath $outer -Value ("& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$($script:ScriptPath)'))) '$($script:Missing)' -NoLaunch -Trust -Yes`n'outer-continues:' + `$LASTEXITCODE")
            $o = & $script:Pwsh -NoProfile -File $outer
            "$o" | Should -Match 'outer-continues:1'
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
    It 'Format-SignerText replaces control and format characters (bidi override) and truncates' {
        $s = "CN=Evil$([char]0x202E)gpj.exe$([char]0x0007)x"
        Format-SignerText $s 200 | Should -Be 'CN=Evil?gpj.exe?x'
        (Format-SignerText ('a' * 300) 200).Length | Should -Be 203
    }
    It 'Get-SystemExePath is rooted at SystemRoot, never a bare name' {
        $old = $env:SystemRoot
        try {
            $env:SystemRoot = 'D:\Win'
            Get-SystemExePath 'explorer.exe' | Should -Match '^D:.Win.explorer\.exe$'
        } finally { $env:SystemRoot = $old }
    }
    It 'Get-FailureText appends the exception HResult in hex, after the message, as a last resort' {
        $ex = New-Object System.Runtime.InteropServices.COMException 'boom', (HResultOf '800B0109')
        $text = try { throw $ex } catch { Get-FailureText $_ }
        $text | Should -Match '0x800B0109'
        Get-FailureCode $text | Should -BeNullOrEmpty        # the message holds no code
        Get-ExceptionCode $text | Should -Contain '0X800B0109'
    }
    It 'Get-FailureText removes the package path and file name from the message' {
        $p = 'C:\Users\me\Downloads\0x80073CFB.msix'
        $text = try { throw ('Deployment failed for ' + $p + ' (0X80073CFB.MSIX)') } catch { Get-FailureText $_ -Path $p }
        $text | Should -Not -Match '80073CFB'
        $text | Should -Match '<package>'
    }
    It 'Get-FailureCode prefers the code after HRESULT: and ignores the exception HResult' {
        Get-FailureCode 'foo 0x80070070 bar HRESULT: 0x80073cfb, x [exception HResult: 0x800B0109]' | Should -Be '0X80073CFB'
        Get-FailureCode 'no code here [exception HResult: 0x800B0109]' | Should -BeNullOrEmpty
    }
    It 'Test-FailureKind: a code decides; wording only without a code' {
        $c = $script:UntrustedCodes; $w = $script:UntrustedWording
        Test-FailureKind 'HRESULT: 0x800B0109 x' $c $w | Should -BeTrue
        Test-FailureKind 'HRESULT: 0x80070070 root certificate of the signature' $c $w | Should -BeFalse
        Test-FailureKind 'root certificate of the signature must be trusted [exception HResult: 0x80131500]' $c $w | Should -BeTrue
        Test-FailureKind 'plain [exception HResult: 0x800B0109]' $c $w | Should -BeTrue
    }
}

Describe 'msixrun (bash) PowerShell snippets' {
    BeforeAll {
        $script:BashText = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'msixrun')
        # Each snippet function is "ps_name() { [ps_id_fn] cat <<'PS' ... PS }".
        $script:Snippets = @{}
        foreach ($m in [regex]::Matches($script:BashText, "(?ms)^(ps_\w+)\(\) \{\s*(ps_id_fn\s*)?cat <<'PS'\r?\n(.*?)^PS\r?$")) {
            $script:Snippets[$m.Groups[1].Value] = [pscustomobject]@{ NeedsId = [bool]$m.Groups[2].Value; Body = $m.Groups[3].Value }
        }
        function Get-SnippetBody([string]$Name) {
            $sn = $script:Snippets[$Name]
            if ($sn.NeedsId) { return $script:Snippets['ps_id_fn'].Body + $sn.Body }
            return $sn.Body
        }
    }
    It 'finds every snippet' {
        $script:Snippets.Keys | Should -Contain 'ps_trust'
        $script:Snippets.Keys | Should -Contain 'ps_install'
        $script:Snippets.Count | Should -BeGreaterOrEqual 8
    }
    It 'parses without errors: <name>' -ForEach @(
        'ps_id_fn', 'ps_manifest', 'ps_install', 'ps_signer', 'ps_trust', 'ps_devmode', 'ps_conflict', 'ps_remove', 'ps_launch' | ForEach-Object { @{ name = $_ } }) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput((Get-SnippetBody $name), [ref]$null, [ref]$errs)
        $errs | Should -BeNullOrEmpty
    }
    Context 'executed with the Windows commands replaced' {
        BeforeAll {
            $script:Pwsh = (Get-Process -Id $PID).Path
            $script:CertB64 = [Convert]::ToBase64String($script:TestCert.RawData)
            $script:Log2 = Join-Path $script:Work 'snippet-calls.log'
            # Runs a snippet in a child PowerShell. $Prelude defines the mocks
            # (functions win over cmdlets). Returns the output lines and exit code.
            function Invoke-Snippet {
                param([string]$Name, [string]$Prelude = '', [string]$Pkg = 'C:\fake\app.msix')
                foreach ($x in '', '.args', '.cer', '.cerpath') { Remove-Item -LiteralPath ($script:Log2 + $x) -ErrorAction SilentlyContinue }
                $text = @(
                    "`$global:CallLog = '" + $script:Log2.Replace("'", "''") + "'"
                    "`$global:Cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String('$($script:CertB64)'))"
                    "function Get-Hr([string]`$h) { [BitConverter]::ToInt32([BitConverter]::GetBytes([Convert]::ToUInt32(`$h, 16)), 0) }"
                    $Prelude
                    "`$pkg = '" + $Pkg.Replace("'", "''") + "'"
                    (Get-SnippetBody $Name)
                ) -join "`n"
                $f = Join-Path $script:Work ('snippet-' + [guid]::NewGuid().ToString('N') + '.ps1')
                Set-Content -LiteralPath $f -Value $text
                $o = & $script:Pwsh -NoProfile -File $f 2>&1
                [pscustomobject]@{ Lines = @($o | ForEach-Object { "$_" }); Code = $LASTEXITCODE }
            }
            $script:SignerMock = 'function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{ Status = ''UnknownError''; SignerCertificate = $global:Cert } }'
            $script:StartMock = 'function Start-Process { param($FilePath, $Verb, [switch]$Wait, [switch]$PassThru, $ArgumentList) Set-Content -LiteralPath $global:CallLog -Value $FilePath; Set-Content -LiteralPath ($global:CallLog + ''.args'') -Value $ArgumentList[4]; $d = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[4])); $cp = [regex]::Match($d, ''\(,.([^\x27]+).\)'').Groups[1].Value; Set-Content -LiteralPath ($global:CallLog + ''.cer'') -Value ([IO.File]::Exists($cp)).ToString(); Set-Content -LiteralPath ($global:CallLog + ''.cerpath'') -Value $cp; %BODY% }'
            $script:ThumbLine = "`n`$expectedThumb = '" + $script:TestCert.Thumbprint + "'`n"
            $script:TestPathMock = 'function Test-Path { param($Path) %BODY% }'
        }
        It 'ps_install: success prints MSIXRUN_OK and passes -AllowUnsigned only when asked' {
            $mock = 'function Add-AppxPackage { param($Path, [switch]$AllowUnsigned) Add-Content -LiteralPath $global:CallLog -Value ("unsigned=" + [bool]$AllowUnsigned) }'
            $r = Invoke-Snippet -Name ps_install -Prelude ($mock + "`n`$allowUnsigned = `$false")
            $r.Code | Should -Be 0
            $r.Lines | Should -Contain 'MSIXRUN_OK'
            (Get-Content -LiteralPath $script:Log2) | Should -Be 'unsigned=False'
            $r = Invoke-Snippet -Name ps_install -Prelude ($mock + "`n`$allowUnsigned = `$true")
            (Get-Content -LiteralPath $script:Log2) | Should -Be 'unsigned=True'
        }
        It 'ps_install: failure prints the HRESULT in hex and the message, and exits 1' {
            $mock = 'function Add-AppxPackage { param($Path, [switch]$AllowUnsigned) throw (New-Object Runtime.InteropServices.COMException "Deployment failed`n  with conflict", (Get-Hr ''0x80073CFB'')) }' + "`n`$allowUnsigned = `$false"
            $r = Invoke-Snippet -Name ps_install -Prelude $mock
            $r.Code | Should -Be 1
            $r.Lines | Should -Contain 'MSIXRUN_HRESULT=0x80073CFB'
            ($r.Lines | Where-Object { $_ -like 'MSIXRUN_MESSAGE=Deployment failed with conflict*' }) | Should -Not -BeNullOrEmpty
            $r.Lines | Should -Not -Contain 'MSIXRUN_OK'
        }
        It 'ps_signer: prints status, strips control and bidi characters, truncates' {
            $mock = 'function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{ Status = ''NotTrusted''; SignerCertificate = [pscustomobject]@{ Subject = ("CN=Evil" + [char]0x202E + "gpj" + [char]7 + ("x" * 300)); Thumbprint = "AABB"; NotAfter = [datetime]''2030-01-02'' } } }'
            $r = Invoke-Snippet -Name ps_signer -Prelude $mock
            $r.Code | Should -Be 0
            $r.Lines | Should -Contain 'STATUS=NotTrusted'
            $r.Lines | Should -Contain 'THUMBPRINT=AABB'
            $r.Lines | Should -Contain 'NOTAFTER=2030-01-02'
            $subject = ($r.Lines | Where-Object { $_ -like 'SUBJECT=*' })
            $subject | Should -Match '^SUBJECT=CN=Evil\?gpj\?x+\.\.\.$'
            $subject.Length | Should -Be (8 + 203)
        }
        It 'ps_trust: success starts the absolute powershell.exe elevated and verifies the store' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 0
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=ok'
            (Get-Content -LiteralPath $script:Log2) | Should -Match $script:PsExeRx
        }
        It 'ps_trust: the elevated command carries only a .cer path and the thumbprint, stays under 2 KB, and the file is removed afterwards' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 0
            $enc = (Get-Content -LiteralPath ($script:Log2 + '.args') -Raw).Trim()
            $enc.Length | Should -BeLessThan 2048
            $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc))
            $cmd | Should -Not -Match 'FromBase64String'
            $cmd | Should -Not -Match ([regex]::Escape($script:CertB64.Substring(0, 40)))
            $cmd | Should -Match ([regex]::Escape($script:TestCert.Thumbprint))
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errs)
            $errs | Should -BeNullOrEmpty
            (Get-Content -LiteralPath ($script:Log2 + '.cer')).Trim() | Should -Be 'True'
            [IO.File]::Exists((Get-Content -LiteralPath ($script:Log2 + '.cerpath')).Trim()) | Should -BeFalse
        }
        It 'ps_trust: refuses when the second read of the signer has a different thumbprint' {
            $mock = "`n`$expectedThumb = '" + ('A' * 40) + "'`n" + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 6
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=changed'
            Test-Path -LiteralPath $script:Log2 | Should -BeFalse   # no elevation
        }
        It 'ps_trust: refuses when the signature status is no longer untrusted-but-valid' -ForEach @(@{ st = 'HashMismatch' }, @{ st = 'NotSigned' }, @{ st = 'Valid' }) {
            $signer = 'function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{ Status = ''' + $st + '''; SignerCertificate = $global:Cert } }'
            $mock = $script:ThumbLine + $signer + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 6
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=changed'
            Test-Path -LiteralPath $script:Log2 | Should -BeFalse
        }
        It 'ps_trust: refuses an expected thumbprint that is not 40 uppercase hex' -ForEach @(@{ th = 'abcd' }, @{ th = '' }, @{ th = "AA'; calc; '" }) {
            $mock = "`n`$expectedThumb = '" + $th.Replace("'", "''") + "'`n" + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 6
            Test-Path -LiteralPath $script:Log2 | Should -BeFalse
        }
        It 'ps_trust: a declined UAC prompt gives declined and exit 3' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', 'throw (New-Object ComponentModel.Win32Exception 1223)') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 3
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=declined'
        }
        It 'ps_trust: another start failure gives failed, the message, and exit 4' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', 'throw ''no elevation available''') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 4
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=failed'
            $r.Lines | Should -Contain 'MSIXRUN_MESSAGE=no elevation available'
        }
        It 'ps_trust: a nonzero exit from the elevated import gives failed and exit 4' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 1 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$true')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 4
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=failed'
            $r.Lines | Should -Contain 'MSIXRUN_MESSAGE=the elevated import exited with code 1'
        }
        It 'ps_trust: a certificate missing from the store afterwards gives unverified and exit 5' {
            $mock = $script:ThumbLine + $script:SignerMock + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }') + "`n" + $script:TestPathMock.Replace('%BODY%', '$false')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 5
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=unverified'
        }
        It 'ps_trust: a package with no signer certificate gives nocert and exit 2, with no elevation' {
            $mock = $script:ThumbLine + 'function Get-AuthenticodeSignature { param($FilePath) [pscustomobject]@{ Status = ''NotSigned''; SignerCertificate = $null } }' + "`n" + $script:StartMock.Replace('%BODY%', '[pscustomobject]@{ ExitCode = 0 }')
            $r = Invoke-Snippet -Name ps_trust -Prelude $mock
            $r.Code | Should -Be 2
            $r.Lines | Should -Contain 'MSIXRUN_RESULT=nocert'
            Test-Path -LiteralPath $script:Log2 | Should -BeFalse
        }
        It 'ps_conflict and ps_remove only touch copies from a different publisher' {
            $pkgPath = New-TestMsix -Dir (Join-Path $script:Work 'conf') -Name 'Acme.App' -Publisher 'CN=Acme'
            $mock = @(
                'function Get-AppxPackage { param($Name) @([pscustomobject]@{ Name = ''Acme.App''; Publisher = ''CN=Acme''; PackageFullName = ''same'' }, [pscustomobject]@{ Name = ''Acme.App''; Publisher = ''CN=Other''; PackageFullName = ''other'' }) }'
                'function Remove-AppxPackage { param($Package) Add-Content -LiteralPath $global:CallLog -Value $Package }'
            ) -join "`n"
            $r = Invoke-Snippet -Name ps_conflict -Prelude $mock -Pkg $pkgPath
            $r.Lines | Should -Contain 'CONFLICT=1'
            $r = Invoke-Snippet -Name ps_remove -Prelude $mock -Pkg $pkgPath
            $r.Code | Should -Be 0
            $r.Lines | Should -Contain 'REMOVED=1'
            @(Get-Content -LiteralPath $script:Log2) | Should -Be @('other')
        }
        It 'ps_remove: a removal failure prints the message and exits 1' {
            $pkgPath = New-TestMsix -Dir (Join-Path $script:Work 'conf2') -Name 'Acme.App' -Publisher 'CN=Acme'
            $mock = @(
                'function Get-AppxPackage { param($Name) @([pscustomobject]@{ Name = ''Acme.App''; Publisher = ''CN=Other''; PackageFullName = ''other'' }) }'
                'function Remove-AppxPackage { param($Package) throw ''in use'' }'
            ) -join "`n"
            $r = Invoke-Snippet -Name ps_remove -Prelude $mock -Pkg $pkgPath
            $r.Code | Should -Be 1
            $r.Lines | Should -Contain 'MSIXRUN_MESSAGE=in use'
        }
        It 'ps_launch prints PackageFamilyName!AppId of the newest install' {
            $pkgPath = New-TestMsix -Dir (Join-Path $script:Work 'conf3') -Name 'Acme.App' -Publisher 'CN=Acme'
            $mock = @(
                'function Get-AppxPackage { param($Name) @([pscustomobject]@{ Version = ''1.0.0.0''; PackageFamilyName = ''Old_x'' }, [pscustomobject]@{ Version = ''2.0.0.0''; PackageFamilyName = ''Acme.App_8wekyb3d8bbwe'' }) }'
                'function Get-AppxPackageManifest { param($Package) [pscustomobject]@{ Package = [pscustomobject]@{ Applications = [pscustomobject]@{ Application = @([pscustomobject]@{ Id = ''App'' }) } } } }'
            ) -join "`n"
            $r = Invoke-Snippet -Name ps_launch -Prelude $mock -Pkg $pkgPath
            $r.Code | Should -Be 0
            $r.Lines[-1] | Should -Be 'Acme.App_8wekyb3d8bbwe!App'
        }
        It 'the bash script launches explorer.exe and powershell.exe by full path or through the shell only' {
            $script:BashText | Should -Not -Match "Start-Process -FilePath powershell\.exe"
            $script:BashText | Should -Match ([regex]::Escape('$psexe = [IO.Path]::Combine($root, ''System32\WindowsPowerShell\v1.0\powershell.exe'')'))
        }
    }
    It 'ps_manifest really reads Name and Publisher from a package' {
        $pkgPath = New-TestMsix -Dir (Join-Path $script:Work 'snip') -Name 'Snip.App' -Publisher 'CN=Snip'
        $body = "`$pkg = '" + $pkgPath.Replace("'", "''") + "'`n" + (Get-SnippetBody 'ps_manifest')
        $out = & ([scriptblock]::Create($body))
        $out | Should -Contain 'NAME=Snip.App'
        $out | Should -Contain 'PUBLISHER=CN=Snip'
    }
}
