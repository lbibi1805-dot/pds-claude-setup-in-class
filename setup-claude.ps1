<#
.SYNOPSIS
    One-shot setup of Claude Code (Claude CLI) on an RMIT lab machine.

.DESCRIPTION
    1. Asks for the student ID (digits only, without the leading "s").
    2. Checks the environment (account, PowerShell, execution policy, Node.js,
       npm, npm global folder, PATH, network) and prints a fix for every problem.
    3. Installs @anthropic-ai/claude-code globally with its postinstall script
       allowed (npm 12 blocks install scripts by default).
    4. Adds the npm global folder to the user PATH (no duplicates) and to the
       current session.
    5. Verifies "claude --version" and explains how to log in.

    Safe to run again: every step checks the current state before changing it.
    Compatible with Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER StudentId
    Student ID without the leading "s" (example: 4029308). Prompted if omitted.

.PARAMETER CheckOnly
    Run the environment checks only; install and change nothing.

.PARAMETER Force
    Reinstall even when a working claude command is already found.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-claude.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-claude.ps1 -StudentId 4029308 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$StudentId,
    [switch]$CheckOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$PackageName        = '@anthropic-ai/claude-code'
$MinNodeMajor       = 18
$NativeInstallerUrl = 'https://claude.ai/install.ps1'
$LogFile            = Join-Path $env:TEMP ('claude-setup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Issues             = New-Object System.Collections.ArrayList

# PowerShell 5.1 may default to old TLS versions; npm/Anthropic endpoints need TLS 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Output helpers (plain-text labels; everything is also written to the log)
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    try { Add-Content -LiteralPath $LogFile -Value $Message -ErrorAction Stop } catch { }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== {0} ===' -f $Title) -ForegroundColor Cyan
    Write-Log ('=== {0} ===' -f $Title)
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK]   $Message" -ForegroundColor Green
    Write-Log "[OK]   $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message"
    Write-Log "[INFO] $Message"
}

function Add-Issue {
    param(
        [ValidateSet('WARN', 'FAIL')][string]$Level,
        [string]$Problem,
        [string[]]$Fix = @()
    )
    $color = 'Yellow'
    if ($Level -eq 'FAIL') { $color = 'Red' }
    Write-Host ('  [{0}] {1}' -f $Level, $Problem) -ForegroundColor $color
    Write-Log ('[{0}] {1}' -f $Level, $Problem)
    $first = $true
    foreach ($line in $Fix) {
        $label = '       '
        if ($first) { $label = '  Fix: ' }
        Write-Host ("     {0}{1}" -f $label, $line)
        Write-Log ("     {0}{1}" -f $label, $line)
        $first = $false
    }
    [void]$Issues.Add([pscustomobject]@{ Level = $Level; Problem = $Problem; Fix = $Fix })
}

function Read-YesNo {
    param([string]$Question, [bool]$Default = $false)
    $suffix = '[y/N]'
    if ($Default) { $suffix = '[Y/n]' }
    try {
        $answer = Read-Host ("  {0} {1}" -f $Question, $suffix)
    } catch {
        return $Default
    }
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return ($answer.Trim() -match '^(y|yes|c|co)$')
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
function Invoke-Native {
    # Runs a command line through cmd.exe so stdout and stderr come back as plain
    # text (Windows PowerShell 5.1 wraps native stderr in error records), and so
    # npm.cmd / claude.cmd are used instead of the .ps1 shims that the execution
    # policy may block.
    param([string]$CommandLine, [switch]$Echo)
    $lines = & cmd.exe /d /c "$CommandLine 2>&1"
    $code = $LASTEXITCODE
    $text = (@($lines) | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($Echo) {
        foreach ($line in @($lines)) { Write-Host "    | $line" -ForegroundColor DarkGray }
    }
    Write-Log "> $CommandLine  (exit code $code)"
    Write-Log $text
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Get-LastLine {
    param([string]$Text)
    $lines = @($Text -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1].Trim()
}

function Get-MajorVersion {
    param([string]$Text)
    if ($Text -match '(\d+)\.(\d+)\.(\d+)') { return [int]$Matches[1] }
    return -1
}

function Format-PathEntry {
    param([string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    return $expanded.TrimEnd('\').ToLowerInvariant()
}

function Test-PathListContains {
    param([string]$PathList, [string]$Directory)
    if ([string]::IsNullOrWhiteSpace($PathList)) { return $false }
    $target = Format-PathEntry $Directory
    foreach ($entry in ($PathList -split ';')) {
        if ($entry.Trim() -and ((Format-PathEntry $entry) -eq $target)) { return $true }
    }
    return $false
}

function Add-UserPathEntry {
    # Appends a folder to the user PATH stored in HKCU\Environment, keeping the
    # existing value type (%VARIABLES% are not expanded) and avoiding duplicates.
    param([string]$Directory)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (Test-PathListContains $raw $Directory) {
            Write-Ok "User PATH already contains $Directory"
        } else {
            $newValue = $Directory
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $newValue = $raw.TrimEnd(';') + ';' + $Directory }
            $key.SetValue('Path', $newValue, [Microsoft.Win32.RegistryValueKind]::ExpandString)
            # Setting a variable through .NET broadcasts WM_SETTINGCHANGE so that
            # windows opened from now on see the new PATH.
            [Environment]::SetEnvironmentVariable('CLAUDE_SETUP_REFRESH', '1', 'User')
            [Environment]::SetEnvironmentVariable('CLAUDE_SETUP_REFRESH', $null, 'User')
            Write-Ok "Added to user PATH: $Directory"
        }
    } catch {
        Add-Issue WARN "Could not update the user PATH: $($_.Exception.Message)" @(
            'Add it manually: Start > "Edit environment variables for your account" > Path > New >',
            $Directory
        )
    } finally {
        $key.Close()
    }
    if (-not (Test-PathListContains $env:Path $Directory)) {
        $env:Path = $env:Path.TrimEnd(';') + ';' + $Directory
        Write-Ok 'Current PowerShell session PATH updated (no restart needed here).'
    }
}

function Test-Url {
    # Returns $null when the host answers (any HTTP status), otherwise the error text.
    param([string]$Url)
    try {
        $null = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        return $null
    } catch {
        if ($_.Exception.Response) { return $null }
        return $_.Exception.Message
    }
}

function Test-FolderWritable {
    param([string]$Directory)
    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Directory ('.write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $probe -Value 'test' -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Get-PersistentExecutionPolicy {
    # The policy a NEW PowerShell window gets: ignores the Process scope, which the
    # launcher sets to Bypass for this window only.
    $list = Get-ExecutionPolicy -List
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $entry = $list | Where-Object { "$($_.Scope)" -eq $scope }
        if ($entry -and "$($entry.ExecutionPolicy)" -ne 'Undefined') {
            return [pscustomobject]@{ Policy = "$($entry.ExecutionPolicy)"; Scope = $scope }
        }
    }
    return [pscustomobject]@{ Policy = 'Restricted'; Scope = 'Default' }
}

function Read-StudentId {
    param([string]$Initial)
    $suggested = $null
    if ($env:USERNAME -match '^[sS](\d+)$') { $suggested = $Matches[1] }
    $candidate = $Initial
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $prompt = '  Enter your student ID without the leading "s" (example: 4029308)'
            if ($suggested) { $prompt = "$prompt [Enter = $suggested]" }
            try {
                $candidate = Read-Host $prompt
            } catch {
                Add-Issue FAIL 'Cannot read keyboard input in this console.' @(
                    'Run the script in a normal PowerShell window, or pass the ID: -StudentId 4029308'
                )
                return $null
            }
            if ([string]::IsNullOrWhiteSpace($candidate) -and $suggested) { $candidate = $suggested }
        }
        $value = ($candidate -replace '\s', '')
        $candidate = $null
        if ($value -match '^[sS](\d+)$') {
            $value = $Matches[1]
            Write-Info 'Removed the leading "s"; the ID is digits only.'
        }
        if ($value -match '^\d{7}$') { return $value }
        if ($value -match '^\d+$') {
            if (Read-YesNo ("'{0}' has {1} digits; RMIT student IDs usually have 7. Use it anyway?" -f $value, $value.Length)) {
                return $value
            }
        } else {
            Write-Host '  Invalid ID: type digits only, for example 4029308.' -ForegroundColor Yellow
        }
    }
    Add-Issue FAIL 'No valid student ID entered after 5 attempts.' @('Run the script again and type digits only, e.g. 4029308.')
    return $null
}

function Show-NpmDiagnosis {
    # Maps known npm error signatures to a concrete fix.
    param([string]$Output, [string]$Prefix)
    $rules = @(
        @{ Pattern = 'EPERM|EACCES|operation not permitted';
           Problem = 'npm has no permission to write to the global folder (EPERM/EACCES).';
           Fix = @('Close every window that is running claude, then run this script again.',
                   "Point npm at your own profile: npm config set prefix `"$env:APPDATA\npm`"") },
        @{ Pattern = 'EBUSY|resource busy or locked';
           Problem = 'A file is locked (EBUSY), usually because claude is still running.';
           Fix = @('Close all claude windows (or: Stop-Process -Name claude) and run the script again.') },
        @{ Pattern = 'ENOTFOUND|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|ENETUNREACH';
           Problem = 'npm cannot reach the package registry (network error).';
           Fix = @('Check the network connection (lab Ethernet/Wi-Fi, campus sign-in page).',
                   'If the campus requires a proxy: npm config set proxy http://HOST:PORT',
                   '                                  npm config set https-proxy http://HOST:PORT') },
        @{ Pattern = 'SELF_SIGNED_CERT|UNABLE_TO_GET_ISSUER_CERT|UNABLE_TO_VERIFY_LEAF_SIGNATURE|CERT_HAS_EXPIRED';
           Problem = 'TLS certificate error: the network is probably inspecting HTTPS traffic.';
           Fix = @('Ask IT for the campus root certificate and run: npm config set cafile "C:\path\to\campus-ca.pem"',
                   'Temporary workaround (less secure): npm config set strict-ssl false',
                   'Undo it afterwards with: npm config delete strict-ssl') },
        @{ Pattern = 'EINTEGRITY|ENOTEMPTY|ECOMPROMISED';
           Problem = 'The npm cache or a previous partial install is corrupted.';
           Fix = @('npm cache clean --force',
                   "Delete `"$Prefix\node_modules\@anthropic-ai\claude-code`" and run the script again.") },
        @{ Pattern = 'ENOSPC|no space left';
           Problem = 'The disk / profile quota is full.';
           Fix = @('Free space in your profile (Downloads, Desktop), then run: npm cache clean --force') },
        @{ Pattern = 'EBADENGINE|Unsupported engine';
           Problem = "The installed Node.js is too old for Claude Code (needs $MinNodeMajor+).";
           Fix = @('Use a newer Node.js, or let this script use the official native installer.') },
        @{ Pattern = 'install-scripts|allowScripts|allow-scripts';
           Problem = 'npm blocked the Claude Code postinstall script, so the claude program was not created.';
           Fix = @("npm install -g --allow-scripts=$PackageName $PackageName",
                   "Or allow it permanently: npm config set allow-scripts=$PackageName --location=user") }
    )
    $matched = $false
    foreach ($rule in $rules) {
        if ($Output -match $rule.Pattern) {
            Add-Issue FAIL $rule.Problem $rule.Fix
            $matched = $true
        }
    }
    if (-not $matched) {
        Add-Issue FAIL 'npm install failed with an unrecognised error.' @(
            "Read the npm output above and the full log: $LogFile",
            'npm writes its own debug log under: %LOCALAPPDATA%\npm-cache\_logs'
        )
    }
}

function Test-ClaudeCommand {
    # Returns the version string when "claude --version" works through cmd.exe.
    $result = Invoke-Native 'claude --version'
    if ($result.ExitCode -eq 0 -and $result.Output -match '\d+\.\d+\.\d+') { return (Get-LastLine $result.Output) }
    return $null
}

function Install-ClaudeNative {
    Write-Info "Running the official native installer: $NativeInstallerUrl"
    try {
        $installer = Invoke-RestMethod -Uri $NativeInstallerUrl -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        & ([scriptblock]::Create($installer))
    } catch {
        Add-Issue FAIL "Native installer failed: $($_.Exception.Message)" @(
            'Check the network connection to claude.ai (see the network checks above).',
            "Or run it yourself: irm $NativeInstallerUrl | iex"
        )
        return $null
    }
    $bin = Join-Path $HOME '.local\bin'
    if (Test-Path -LiteralPath (Join-Path $bin 'claude.exe')) {
        Add-UserPathEntry $bin
        return $bin
    }
    Add-Issue FAIL "The native installer finished but $bin\claude.exe was not found." @(
        "Check the installer output above and the log: $LogFile"
    )
    return $null
}

# ===========================================================================
# Main
# ===========================================================================
Write-Host ''
Write-Host 'Claude Code setup for RMIT lab machines' -ForegroundColor Cyan
if ($CheckOnly) { Write-Host 'Mode: check only (nothing will be installed or changed)' }
Write-Host "Log file: $LogFile"
Write-Log "Started $(Get-Date -Format s) as $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME"

# ---------------------------------------------------------------------------
Write-Section '1. Student account'
$id = Read-StudentId $StudentId
if (-not $id) { exit 1 }
$sid = "s$id"
$usersRoot = Split-Path $env:USERPROFILE -Parent
$expectedHome = Join-Path $usersRoot $sid
Write-Info "Student ID: $id  (Windows account expected: $sid, home: $expectedHome)"

if ($env:USERNAME -ieq $sid) {
    Write-Ok "Logged in as $env:USERNAME, home folder $env:USERPROFILE"
} else {
    Add-Issue WARN "You are logged in as '$env:USERNAME', not '$sid'. Claude would be installed for '$env:USERNAME'." @(
        "If the ID is wrong, run the script again and type the correct ID.",
        "If the account is wrong, sign out and sign in with your student account $sid."
    )
    if (-not $CheckOnly) {
        if (-not (Read-YesNo "Continue and install for '$env:USERNAME' anyway?" $false)) {
            Write-Host '  Stopped by user.'
            exit 1
        }
    }
}

# ---------------------------------------------------------------------------
Write-Section '2. Environment checks'
Write-Info ("Windows {0}, PowerShell {1} ({2})" -f [Environment]::OSVersion.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
if (-not [Environment]::Is64BitOperatingSystem) {
    Add-Issue WARN '32-bit Windows detected; Claude Code supports 64-bit Windows only.' @('Use a 64-bit lab machine.')
}

# Execution policy (affects claude.ps1 / npm.ps1 shims in new PowerShell windows)
$policy = Get-PersistentExecutionPolicy
$policyNeedsFix = $false
if ($policy.Policy -in 'Restricted', 'AllSigned') {
    if ($policy.Scope -in 'MachinePolicy', 'UserPolicy') {
        Add-Issue WARN "Execution policy '$($policy.Policy)' is enforced by Group Policy: typing 'claude' in PowerShell will fail with 'running scripts is disabled on this system'." @(
            'Type claude.cmd instead of claude (and npm.cmd instead of npm) in PowerShell.',
            'Or use Command Prompt (cmd.exe), where claude works normally.'
        )
    } else {
        Add-Issue WARN "Execution policy is '$($policy.Policy)' ($($policy.Scope)): typing 'claude' in PowerShell will fail with 'running scripts is disabled on this system'." @(
            'Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force',
            'The script offers to apply this in step 3.'
        )
        $policyNeedsFix = $true
    }
} else {
    Write-Ok "Execution policy for new windows: $($policy.Policy) ($($policy.Scope))"
}

# Node.js
$nodeOk = $false
$nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCmd) {
    Add-Issue FAIL 'Node.js was not found on PATH.' @(
        'Open a new terminal and check: where.exe node',
        'Or use the official native installer (no Node.js needed); the script offers it in step 4.'
    )
} else {
    $nodeVersion = Get-LastLine (Invoke-Native 'node --version').Output
    $nodeMajor = Get-MajorVersion $nodeVersion
    if ($nodeMajor -ge $MinNodeMajor) {
        Write-Ok "Node.js $nodeVersion  ($($nodeCmd.Source))"
        $nodeOk = $true
    } else {
        Add-Issue FAIL "Node.js $nodeVersion is too old; Claude Code needs Node.js $MinNodeMajor or newer." @(
            'Use a newer Node.js, or use the native installer that the script offers in step 4.'
        )
    }
}

# npm
$npmOk = $false
$npmMajor = -1
$prefix = $null
if ($nodeCmd) {
    $npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $npmCmd) {
        Add-Issue FAIL 'npm was not found (Node.js is present but npm.cmd is missing from PATH).' @(
            'Reinstall Node.js with npm, or use the native installer offered in step 4.'
        )
    } else {
        $npmVersion = Get-LastLine (Invoke-Native 'npm --version').Output
        $npmMajor = Get-MajorVersion $npmVersion
        if ($npmMajor -lt 0) {
            Add-Issue FAIL "npm did not return a version: '$npmVersion'." @("See the log: $LogFile")
        } else {
            Write-Ok "npm $npmVersion"
            $npmOk = $true
            if ($npmMajor -ge 12) {
                Write-Info 'npm 12+ blocks package install scripts by default; the script will pass --allow-scripts for Claude Code.'
            }
        }
    }
}

# npm global folder (prefix)
$prefixNeedsFix = $false
$prefixFixDefault = $true
$defaultPrefix = Join-Path $env:APPDATA 'npm'
if ($npmOk) {
    $prefix = Get-LastLine (Invoke-Native 'npm config get prefix').Output
    Write-Info "npm global folder (prefix): $prefix"
    $insideProfile = (Format-PathEntry $prefix).StartsWith((Format-PathEntry $env:USERPROFILE) + '\')
    if (-not (Test-FolderWritable $prefix)) {
        Add-Issue FAIL "The npm global folder is not writable for '$env:USERNAME': $prefix" @(
            "npm config set prefix `"$defaultPrefix`"",
            'The script offers to apply this in step 3.'
        )
        $prefixNeedsFix = $true
    } elseif (-not $insideProfile) {
        Add-Issue WARN "The npm global folder is outside your profile ($prefix); it may be wiped or shared between users." @(
            "npm config set prefix `"$defaultPrefix`"",
            'The script offers to apply this in step 3 (default No, because the folder works).'
        )
        $prefixNeedsFix = $true
        $prefixFixDefault = $false
    } else {
        Write-Ok 'npm global folder is inside your profile and writable.'
    }
    if ($prefix -and -not (Test-PathListContains $env:Path $prefix)) {
        Add-Issue WARN "The npm global folder is not on PATH; this causes: 'claude' is not recognized as the name of a cmdlet..." @(
            'The script adds it to your user PATH in step 5.'
        )
    } elseif ($prefix) {
        Write-Ok 'npm global folder is on PATH.'
    }
}

# Network
$registryError = Test-Url 'https://registry.npmjs.org/'
if ($registryError) {
    $fix = @('Check the network connection (lab Ethernet/Wi-Fi, campus sign-in page).',
             'If the campus requires a proxy: npm config set https-proxy http://HOST:PORT')
    if ($registryError -match 'trust|certificate|SSL|TLS') {
        $fix += 'HTTPS inspection detected: ask IT for the root certificate (npm config set cafile ...).'
    }
    Add-Issue FAIL "Cannot reach the npm registry: $registryError" $fix
} else {
    Write-Ok 'npm registry reachable (registry.npmjs.org).'
}
foreach ($url in 'https://api.anthropic.com', 'https://claude.ai') {
    $err = Test-Url $url
    if ($err) {
        Add-Issue WARN "Cannot reach ${url}: $err" @(
            'Claude may install but cannot log in or answer. Check firewall/proxy;',
            'for a proxy set it for Claude too: $env:HTTPS_PROXY = "http://HOST:PORT"'
        )
    } else {
        Write-Ok "$url reachable."
    }
}
foreach ($var in 'HTTPS_PROXY', 'HTTP_PROXY') {
    $value = [Environment]::GetEnvironmentVariable($var)
    if ($value) { Write-Info "$var is set: $value" }
}

# Existing installation
$existingVersion = Test-ClaudeCommand
$nativeBin = Join-Path $HOME '.local\bin'
if ($existingVersion) {
    Write-Ok "claude already works: $existingVersion"
} elseif ($prefix -and (Test-Path -LiteralPath (Join-Path $prefix 'claude.cmd'))) {
    Add-Issue WARN "claude.cmd exists in $prefix but 'claude --version' does not work yet (PATH or a blocked postinstall)." @(
        'Steps 4 and 5 reinstall it with scripts allowed and fix PATH.'
    )
} elseif (Test-Path -LiteralPath (Join-Path $nativeBin 'claude.exe')) {
    Add-Issue WARN "A native install exists in $nativeBin but is not on PATH." @('Step 5 adds it to PATH.')
} else {
    Write-Info 'Claude Code is not installed yet.'
}

if ($CheckOnly) {
    Write-Section 'Summary (check only)'
} else {
    # -----------------------------------------------------------------------
    Write-Section '3. Apply environment fixes'
    $anyFix = $false
    if ($policyNeedsFix) {
        $anyFix = $true
        if (Read-YesNo 'Set the execution policy for your account to RemoteSigned (lets "claude" run in PowerShell)?' $true) {
            try {
                Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
                Write-Ok 'Execution policy for CurrentUser set to RemoteSigned.'
            } catch {
                Add-Issue WARN "Could not change the execution policy: $($_.Exception.Message)" @(
                    'Use claude.cmd instead of claude in PowerShell, or use Command Prompt.'
                )
            }
        }
    }
    if ($prefixNeedsFix) {
        $anyFix = $true
        if (Read-YesNo "Change the npm global folder to $defaultPrefix ?" $prefixFixDefault) {
            $null = Invoke-Native ("npm config set prefix `"{0}`"" -f $defaultPrefix)
            $prefix = Get-LastLine (Invoke-Native 'npm config get prefix').Output
            if ((Format-PathEntry $prefix) -eq (Format-PathEntry $defaultPrefix)) {
                Write-Ok "npm global folder is now $prefix"
            } else {
                Add-Issue FAIL "npm still reports prefix '$prefix'." @(
                    'Check for a prefix line in %USERPROFILE%\.npmrc or an NPM_CONFIG_PREFIX variable.'
                )
            }
        }
    }
    if (-not $anyFix) { Write-Ok 'Nothing to fix.' }

    # -----------------------------------------------------------------------
    Write-Section '4. Install Claude Code'
    $installedVia = $null
    $doInstall = $true
    if ($existingVersion -and -not $Force) {
        $doInstall = Read-YesNo "Claude Code $existingVersion is already installed. Reinstall/update it?" $false
        if (-not $doInstall) { Write-Ok 'Keeping the existing installation.' }
    }

    if ($doInstall) {
        $running = Get-Process -Name claude -ErrorAction SilentlyContinue
        if ($running) {
            Add-Issue WARN 'claude is running; npm cannot replace files that are in use (EBUSY/EPERM).' @(
                'Close the claude windows, or let the script stop them now.'
            )
            if (Read-YesNo 'Stop the running claude processes now?' $true) {
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        }

        if ($nodeOk -and $npmOk) {
            $useAllowFlag = ($npmMajor -ge 12)
            $installOk = $false
            for ($try = 1; $try -le 2; $try++) {
                $commandLine = "npm install -g $PackageName"
                if ($useAllowFlag) { $commandLine = "npm install -g --allow-scripts=$PackageName $PackageName" }
                Write-Info "Running: $commandLine"
                $result = Invoke-Native $commandLine -Echo
                $blocked = $result.Output -match 'install-scripts' -and $result.Output -match 'blocked'
                if ($result.ExitCode -eq 0 -and -not $blocked) { $installOk = $true; break }
                if ($blocked -and -not $useAllowFlag) {
                    Write-Info 'npm blocked the postinstall script; retrying with --allow-scripts.'
                    $useAllowFlag = $true
                    continue
                }
                Show-NpmDiagnosis $result.Output $prefix
                break
            }
            if ($installOk) {
                $shim = Join-Path $prefix 'claude.cmd'
                if (Test-Path -LiteralPath $shim) {
                    Write-Ok "npm install finished; found $shim"
                    $installedVia = 'npm'
                } else {
                    Add-Issue FAIL "npm reported success but $shim was not created." @(
                        "npm install -g --allow-scripts=$PackageName $PackageName"
                    )
                }
            } elseif (Read-YesNo 'npm install failed. Try the official native installer instead?' $true) {
                if (Install-ClaudeNative) { $installedVia = 'native' }
            }
        } else {
            Write-Info 'Node.js/npm is not usable, so npm install is not possible.'
            if (Read-YesNo "Use the official native installer ($NativeInstallerUrl)?" $true) {
                if (Install-ClaudeNative) { $installedVia = 'native' }
            }
        }
    }

    # -----------------------------------------------------------------------
    Write-Section '5. PATH'
    if ($prefix -and (Test-Path -LiteralPath (Join-Path $prefix 'claude.cmd'))) { Add-UserPathEntry $prefix }
    if (Test-Path -LiteralPath (Join-Path $nativeBin 'claude.exe')) { Add-UserPathEntry $nativeBin }

    # -----------------------------------------------------------------------
    Write-Section '6. Verify'
    $finalVersion = Test-ClaudeCommand
    if (-not $finalVersion -and $prefix) {
        # The npm package downloads its native binary in install.cjs; run it by hand
        # when npm skipped it.
        $installScript = Join-Path $prefix 'node_modules\@anthropic-ai\claude-code\install.cjs'
        if ((Test-Path -LiteralPath $installScript) -and (Read-YesNo 'claude does not run yet. Run the package postinstall (install.cjs) manually now?' $true)) {
            $null = Invoke-Native ("node `"{0}`"" -f $installScript) -Echo
            $finalVersion = Test-ClaudeCommand
        }
    }
    if ($finalVersion) {
        Write-Ok "claude --version -> $finalVersion"
        # Check what a brand-new PowerShell window will see (execution policy + PATH).
        $fresh = Invoke-Native 'powershell.exe -NoProfile -Command "claude --version"'
        if ($fresh.ExitCode -eq 0 -and $fresh.Output -match '\d+\.\d+\.\d+') {
            Write-Ok 'A new PowerShell window can run "claude" directly.'
        } elseif ($fresh.Output -match 'running scripts is disabled|cannot be loaded') {
            Add-Issue WARN 'In a new PowerShell window "claude" is blocked by the execution policy.' @(
                'Type claude.cmd instead, or run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force'
            )
        } else {
            Add-Issue WARN 'A new PowerShell window could not run "claude" yet.' @(
                'Close ALL terminals (including VS Code) and open a new one; PATH is read when a window starts.',
                'In this window it already works.'
            )
        }
    } else {
        Add-Issue FAIL "'claude --version' still fails." @(
            "Read the messages above and the log: $LogFile",
            "Manual install: npm install -g --allow-scripts=$PackageName $PackageName",
            "Or native: irm $NativeInstallerUrl | iex"
        )
    }

    Write-Section 'Summary'
}

# ---------------------------------------------------------------------------
$fails = @($Issues | Where-Object { $_.Level -eq 'FAIL' })
$warns = @($Issues | Where-Object { $_.Level -eq 'WARN' })
Write-Host ("  {0} problem(s), {1} warning(s)." -f $fails.Count, $warns.Count)
foreach ($issue in $Issues) {
    Write-Host ("  [{0}] {1}" -f $issue.Level, $issue.Problem)
    foreach ($line in $issue.Fix) { Write-Host "         $line" }
}
Write-Host "  Full log: $LogFile"

if (-not $CheckOnly -and $finalVersion) {
    Write-Host ''
    Write-Host 'Next steps' -ForegroundColor Cyan
    Write-Host '  1. cd to your work folder, e.g.:  cd "$HOME\Desktop\a2"'
    Write-Host '  2. Run:  claude      (if PowerShell blocks it: claude.cmd)'
    Write-Host '  3. First run opens a browser to log in. If no browser opens, copy the URL from the terminal.'
    Write-Host '  4. Health check:  claude doctor'
    Write-Host '  5. Before leaving the lab machine: run /logout inside claude (shared computer).'
    if (Read-YesNo 'Start claude now?' $false) {
        $folder = $null
        try { $folder = Read-Host '  Work folder [Enter = current folder]' } catch { }
        if (-not [string]::IsNullOrWhiteSpace($folder)) {
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            Set-Location -LiteralPath $folder
        }
        & cmd.exe /d /c claude
    }
}

if ($fails.Count -gt 0) { exit 1 }
exit 0
