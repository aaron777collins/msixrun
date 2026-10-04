<#
.SYNOPSIS
  Install and launch an MSIX/APPX package, and trust its publisher if you say so.

.DESCRIPTION
  msixrun 1.1.0. Works in Windows PowerShell 5.1 and PowerShell 7.

  Run it straight from the web, nothing saved, no execution policy change:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/aaron777collins/msixrun/main/msixrun.ps1))) <path-or-url> [-NoLaunch] [-Trust] [-Yes]

  Or save it and run it:

    .\msixrun.ps1 <path-or-url> [-NoLaunch] [-Trust] [-Yes]

.PARAMETER Source
  A local .msix, .msixbundle, .appx or .appxbundle file, or an http(s) URL to one.

.PARAMETER NoLaunch
  Install only. Do not start the app.

.PARAMETER Trust
  If Windows does not trust the package's publisher, trust that one publisher
  certificate (this PC only) without asking.

.PARAMETER Yes
  Answer yes to every question: trust the publisher, remove an older copy from
  a different publisher, install unsigned when Developer Mode allows it.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Source,
    [switch]$NoLaunch,
    [switch]$Trust,
    [switch]$Yes,
    [switch]$Version,
    [switch]$Help
)

$script:MsixrunVersion = '1.1.0'

# Windows' own wording for each failure; the codes come from the exception text.
$script:UntrustedPattern = '0x800B0109|0x800B010A|0x800B0112|0x800B0004|root certificate of the signature|chain.*cannot be built'
$script:UnsignedPattern  = '0x800B0100|must be digitally signed|not signed'

function Show-MsixrunUsage {
    Write-Host @"
msixrun $script:MsixrunVersion - install and launch an MSIX package

Usage: msixrun.ps1 <file-or-url.msix|.msixbundle|.appx|.appxbundle> [-NoLaunch] [-Trust] [-Yes]

The package can be a local file or an http(s) URL (it is downloaded first).

  -NoLaunch   install only, do not start the app
  -Trust      if Windows does not trust the package's publisher, trust that one
              publisher certificate (this PC only) without asking
  -Yes        answer yes to every question (trust the publisher, remove an
              older copy from a different publisher, install unsigned when
              Developer Mode allows it)
  -Help       show this help
  -Version    show version
"@
}

# Stop with a message for the person at the keyboard. Caught in Invoke-Msixrun.
function Write-MsixrunFatal {
    param([string]$Message)
    $ex = New-Object System.Exception $Message
    $ex.Data['msixrun'] = $true
    throw $ex
}

function Test-Interactive {
    if (-not [Environment]::UserInteractive) { return $false }
    foreach ($a in [Environment]::GetCommandLineArgs()) {
        if ($a -like '-NonI*') { return $false }
    }
    try { if ([Console]::IsInputRedirected) { return $false } } catch { Write-Verbose 'could not tell whether input is redirected' }
    return $true
}

function Read-Answer {
    param([string]$Prompt)
    Write-Host "$Prompt " -NoNewline
    return (Read-Host)
}

# Ask a yes/no question. $Auto is true when a switch already answers yes;
# $SwitchName says which one. With no terminal and no switch, stop and name the
# switch to use.
function Confirm-Msixrun {
    param([string]$Prompt, [bool]$Auto, [string]$SwitchName, [string]$NoTerminalMessage)
    if ($Auto) {
        Write-Host "$Prompt y (-$SwitchName)"
        return $true
    }
    if (-not (Test-Interactive)) { Write-MsixrunFatal $NoTerminalMessage }
    $answer = Read-Answer $Prompt
    return ($answer -match '^(y|yes)$')
}

function Test-DeveloperMode {
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction Stop).AllowDevelopmentWithoutDevLicense
        return ($v -eq 1)
    } catch {
        return $false
    }
}

function Test-AllowUnsignedSupported {
    $cmd = Get-Command Add-AppxPackage -ErrorAction SilentlyContinue
    return [bool]($cmd -and $cmd.Parameters.ContainsKey('AllowUnsigned'))
}

function Test-PackageExtension {
    param([string]$Name)
    return ($Name -match '\.(msix|msixbundle|appx|appxbundle)$')
}

# Local file or URL in, a usable local path out. Anything downloaded or copied
# goes in $State.TempDir, which the caller removes.
function Get-PackageFile {
    param([string]$Source, $State)

    if ($Source -match '^https?://') {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { Write-Verbose 'could not set TLS 1.2' }
        $leaf = ''
        try { $leaf = [IO.Path]::GetFileName([Uri]::UnescapeDataString(([Uri]$Source).AbsolutePath)) } catch { Write-Verbose 'URL has no usable file name' }
        $leaf = $leaf -replace '[^A-Za-z0-9._-]', '_'
        if (-not (Test-PackageExtension $leaf)) { $leaf = 'download.msix' }
        $State.TempDir = Initialize-MsixrunTempDir
        $dest = Join-Path $State.TempDir $leaf
        Write-Host "Downloading $Source ..."
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'   # the progress bar makes 5.1 downloads very slow
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Source -OutFile $dest -ErrorAction Stop
        } catch {
            Write-MsixrunFatal "download failed: $Source ($($_.Exception.Message))"
        } finally {
            $ProgressPreference = $oldProgress
        }
        return $dest
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { Write-MsixrunFatal "file not found: $Source" }
    if (-not (Test-PackageExtension $Source)) { Write-MsixrunFatal "expected a .msix, .msixbundle, .appx or .appxbundle file: $Source" }
    $full = (Resolve-Path -LiteralPath $Source).ProviderPath
    # Add-AppxPackage -Path treats [ ] * ? as wildcards, so use a plain copy.
    if ($full -match '[\[\]*?]') {
        $State.TempDir = Initialize-MsixrunTempDir
        $copy = Join-Path $State.TempDir ((Split-Path -Leaf $full) -replace '[^A-Za-z0-9._-]', '_')
        Copy-Item -LiteralPath $full -Destination $copy -ErrorAction Stop
        return $copy
    }
    return $full
}

function Initialize-MsixrunTempDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('msixrun-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

# The package is a zip; read Name and Publisher from its manifest.
function Get-MsixId {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $e = $zip.Entries | Where-Object { $_.FullName -in 'AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
        if (-not $e) { throw 'no AppxManifest.xml or AppxBundleManifest.xml found in package' }
        $r = New-Object IO.StreamReader($e.Open())
        try { [xml]$x = $r.ReadToEnd() } finally { $r.Dispose() }
        $id = if ($x.Package) { $x.Package.Identity } else { $x.Bundle.Identity }
        return [pscustomobject]@{ Name = [string]$id.Name; Publisher = [string]$id.Publisher }
    } finally {
        $zip.Dispose()
    }
}

# All the text Windows gave us about a failure, with the HRESULT in hex.
function Get-FailureText {
    param($ErrorRecord)
    $parts = New-Object System.Collections.Generic.List[string]
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $parts.Add([string]$ex.Message)
        try { $parts.Add(('0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$ex.HResult), 0))) } catch { Write-Verbose 'exception has no HResult' }
        $ex = $ex.InnerException
    }
    $parts.Add([string]$ErrorRecord.FullyQualifiedErrorId)
    return (($parts -join ' ') -replace '\s+', ' ')
}

# Returns $null on success, or the failure text.
function Install-Msix {
    param([string]$Path, [bool]$AllowUnsigned)
    try {
        if ($AllowUnsigned) {
            Add-AppxPackage -Path $Path -AllowUnsigned -ErrorAction Stop
        } else {
            Add-AppxPackage -Path $Path -ErrorAction Stop
        }
        return $null
    } catch {
        return (Get-FailureText $_)
    }
}

function Get-SignerInfo {
    param([string]$Path)
    $sig = Get-AuthenticodeSignature -FilePath $Path
    $c = $sig.SignerCertificate
    if (-not $c) { return $null }
    return [pscustomobject]@{
        Certificate = $c
        Subject     = [regex]::Replace([string]$c.Subject, '\p{Cc}+', ' ')
        Thumbprint  = [regex]::Replace([string]$c.Thumbprint, '\p{Cc}+', ' ')
        NotAfter    = $c.NotAfter.ToString('yyyy-MM-dd')
    }
}

# Double single quotes (and the curly ones PowerShell also treats as quotes).
function ConvertTo-PsQuoted {
    param([string]$Value)
    return [regex]::Replace($Value, '([''\u2018\u2019\u201A\u201B])', '$1$1')
}

function Test-UacDeclined {
    param($Exception)
    $e = $Exception
    while ($e) {
        if (($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) -or $e.Message -match 'cancell?ed by the user') { return $true }
        $e = $e.InnerException
    }
    return $false
}

# Export THIS package's signer certificate and import it into
# LocalMachine\TrustedPeople in one elevated child. The child's command is
# passed as -EncodedCommand (Base64 of UTF-16LE), so no text is ever parsed as
# part of a command line. Never the Root store.
function Add-SignerTrust {
    param($Signer)
    $cer = Join-Path ([IO.Path]::GetTempPath()) ('msixrun-' + [guid]::NewGuid().ToString('N') + '.cer')
    try {
        Export-Certificate -Cert $Signer.Certificate -FilePath $cer -Type CERT | Out-Null
        $inner = '$ErrorActionPreference = ''Stop''; try { Import-Certificate -FilePath ''' + (ConvertTo-PsQuoted $cer) + ''' -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null } catch { exit 1 }'
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
        try {
            $p = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ErrorAction Stop `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
        } catch {
            if (Test-UacDeclined $_.Exception) {
                Write-MsixrunFatal "permission was declined, so $($Signer.Subject) was not trusted. Nothing was changed."
            }
            Write-MsixrunFatal "could not start the elevated step: $($_.Exception.Message)"
        }
        if ($p.ExitCode -ne 0) { Write-MsixrunFatal "could not trust the certificate: the elevated import exited with code $($p.ExitCode)" }
        if (-not (Test-Path -LiteralPath ('Cert:\LocalMachine\TrustedPeople\' + $Signer.Thumbprint))) {
            Write-MsixrunFatal 'the certificate import ran but the thumbprint is not in Trusted People. Nothing was installed.'
        }
    } finally {
        Remove-Item -LiteralPath $cer -Force -ErrorAction SilentlyContinue
    }
}

# Installed copies with the same Name from a different publisher.
function Get-ConflictingPackage {
    param($Id)
    return @(Get-AppxPackage -Name $Id.Name | Where-Object { $_.Name -eq $Id.Name -and $_.Publisher -ne $Id.Publisher })
}

# Returns the process exit code. Never calls exit, so it is safe in a
# scriptblock run from someone's interactive window.
function Invoke-Msixrun {
    param([string]$Source, [bool]$NoLaunch, [bool]$Trust, [bool]$Yes)

    $state = @{ TempDir = $null }
    try {
        # 1. Get the package.
        $pkg = Get-PackageFile -Source $Source -State $state

        # 2. Read its identity.
        Write-Host 'Reading package manifest...'
        try { $id = Get-MsixId -Path $pkg } catch { Write-MsixrunFatal "could not read the package manifest: $($_.Exception.Message)" }
        if (-not $id.Name) { Write-MsixrunFatal 'could not determine package name from manifest' }
        if ($id.Name -notmatch '^[A-Za-z0-9.-]+$') { Write-MsixrunFatal 'refusing a package name with unexpected characters' }
        $name = $id.Name
        Write-Host "Package: $name"

        # 3. Install, with one fix per known problem.
        $allowUnsigned = $false
        $trustDone = $false; $unsignedDone = $false; $conflictDone = $false
        while ($true) {
            Write-Host "Installing $pkg ..."
            $failure = Install-Msix -Path $pkg -AllowUnsigned $allowUnsigned
            if ($null -eq $failure) { break }

            # 3a. The publisher is not trusted.
            if ($failure -match $script:UntrustedPattern -and -not $trustDone) {
                $signer = Get-SignerInfo -Path $pkg
                if (-not $signer) { Write-MsixrunFatal "Windows does not trust this package's publisher, and msixrun could not read the signer certificate: $failure" }
                Write-Host ''
                Write-Host "Signer:      $($signer.Subject)"
                Write-Host "Thumbprint:  $($signer.Thumbprint) (SHA-1)"
                Write-Host "Valid until: $($signer.NotAfter)"
                $auto = ($Trust -or $Yes)
                $sw = if ($Yes) { 'Yes' } else { 'Trust' }
                $ok = Confirm-Msixrun -Prompt "Windows does not trust the publisher of this package. Trust $($signer.Subject) and install? [y/N]" `
                    -Auto $auto -SwitchName $sw `
                    -NoTerminalMessage "Windows does not trust the publisher of this package ($($signer.Subject)) and there is no terminal to ask. Re-run with -Trust to trust this publisher, or -Yes to answer yes to everything."
                if (-not $ok) { Write-MsixrunFatal "not installed: you chose not to trust $($signer.Subject)" }
                Write-Host 'Windows will ask for permission once (UAC).'
                Add-SignerTrust -Signer $signer
                Write-Host "Trusted $($signer.Subject) on this PC (Local Machine, Trusted People)."
                $trustDone = $true
                continue
            }

            # 3b. The package is not signed at all.
            if ($failure -match $script:UnsignedPattern -and -not $unsignedDone) {
                $dev = Test-DeveloperMode
                $canUnsigned = Test-AllowUnsignedSupported
                if ($dev -and $canUnsigned) {
                    $ok = Confirm-Msixrun -Prompt 'This package is not signed. Developer Mode is on, so it can be installed unsigned. Install it anyway? [y/N]' `
                        -Auto $Yes -SwitchName 'Yes' `
                        -NoTerminalMessage 'this package is not signed. Re-run with -Yes to install it unsigned (Developer Mode is on).'
                    if (-not $ok) { Write-MsixrunFatal 'not installed: you chose not to install an unsigned package' }
                    $allowUnsigned = $true; $unsignedDone = $true
                    continue
                }
                if ($dev) {
                    Write-MsixrunFatal 'this package is not signed, and this version of Windows cannot install unsigned packages. Sign it, or use a newer Windows build.'
                }
                Write-MsixrunFatal ("this package is not signed, and Developer Mode is off.`n" +
                    "Turn Developer Mode on, then run this again:`n" +
                    "  Windows 11: Settings > System > For developers > Developer Mode`n" +
                    '  Windows 10: Settings > Update & Security > For developers > Developer Mode')
            }

            # 3c. An older copy from a different publisher is in the way.
            if (-not $conflictDone) {
                $old = @(Get-ConflictingPackage -Id $id)
                if ($old.Count -gt 0) {
                    $ok = Confirm-Msixrun -Prompt "An older $name from a different publisher is installed. Remove it and install this one? Its local data will be removed. [y/N]" `
                        -Auto $Yes -SwitchName 'Yes' `
                        -NoTerminalMessage "an older $name from a different publisher is installed. Re-run with -Yes to remove it (its local data is removed) and install this one."
                    if (-not $ok) { Write-MsixrunFatal "not installed: you chose to keep the older $name" }
                    foreach ($o in $old) {
                        try { Remove-AppxPackage -Package $o.PackageFullName -ErrorAction Stop }
                        catch { Write-MsixrunFatal "could not remove the older ${name}: $($_.Exception.Message)" }
                    }
                    $conflictDone = $true
                    continue
                }
            }

            Write-MsixrunFatal "install failed: $failure"
        }

        if ($NoLaunch) {
            Write-Host "Installed $name."
            return 0
        }

        # 4. Look up PackageFamilyName and the first app Id, then launch.
        $installed = Get-AppxPackage -Name $name | Sort-Object { [version]$_.Version } | Select-Object -Last 1
        if (-not $installed) { Write-MsixrunFatal 'installed, but the package was not found afterwards' }
        $appId = @((Get-AppxPackageManifest -Package $installed).Package.Applications.Application)[0].Id
        if (-not $appId) { Write-MsixrunFatal 'installed, but the package declares no launchable application' }
        $info = [string]$installed.PackageFamilyName + '!' + [string]$appId
        if ($info -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') { Write-MsixrunFatal 'installed, but could not resolve PackageFamilyName!AppId' }
        Write-Host "Launching $info"
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('shell:AppsFolder\' + $info) -ErrorAction SilentlyContinue
        return 0
    } catch {
        if ($_.Exception.Data['msixrun']) {
            Write-Host "msixrun: error: $($_.Exception.Message)" -ForegroundColor Red
        } else {
            Write-Host "msixrun: unexpected error: $($_.Exception.Message)" -ForegroundColor Red
        }
        return 1
    } finally {
        if ($state.TempDir) { Remove-Item -LiteralPath $state.TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Run unless this file was dot-sourced (the tests dot-source it).
if ($MyInvocation.InvocationName -ne '.') {
    if ($Help) {
        Show-MsixrunUsage
        $code = 0
    } elseif ($Version) {
        Write-Host "msixrun $script:MsixrunVersion"
        $code = 0
    } elseif (-not $Source) {
        Show-MsixrunUsage
        $code = 1
    } else {
        $code = @(Invoke-Msixrun -Source $Source -NoLaunch ([bool]$NoLaunch) -Trust ([bool]$Trust) -Yes ([bool]$Yes))[-1]
    }
    # A saved script can exit; in a scriptblock that would close the user's window.
    if ($PSCommandPath) { exit $code }
    $global:LASTEXITCODE = $code
}
