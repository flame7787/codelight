#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Name = $(
        if ($env:CODELIGHT_NAME) { $env:CODELIGHT_NAME }
        elseif ($env:COMPUTERNAME) { $env:COMPUTERNAME.ToLowerInvariant() }
        else { "codelight-windows" }
    ),
    [string]$Agents = "codex",
    [switch]$CompanionVerbose
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
Set-Location $Root

function Find-CodexExecutable {
    $codexRoot = Join-Path $env:USERPROFILE ".codex"

    if (Test-Path -LiteralPath $codexRoot) {
        $appServer = Get-ChildItem -LiteralPath $codexRoot -Filter "codex.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]plugins[\\/].*plugin-appserver' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($appServer) { return $appServer.FullName }
    }

    $pathCodex = Get-Command codex.exe -ErrorAction SilentlyContinue
    if (-not $pathCodex) { $pathCodex = Get-Command codex -ErrorAction SilentlyContinue }
    if ($pathCodex) { return $pathCodex.Source }

    return $null
}

function Stop-ExistingCodelightListener {
    $listeners = @(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)

    foreach ($listener in $listeners) {
        $ownerPid = $listener.OwningProcess
        if (-not $ownerPid) { continue }

        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
        if (-not $owner) { continue }

        if ($owner.CommandLine -match '(?i)codelight\.py') {
            Write-Host "Stopping existing codelight companion (PID $ownerPid)..."
            Stop-Process -Id $ownerPid -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
        }
        else {
            throw "TCP port 8765 is already in use by PID $ownerPid ($($owner.Name))."
        }
    }
}

function Assert-WindowsHookTransport {
    if ($env:OS -ne "Windows_NT") { return }

    $hookIo = Join-Path $Root "companion\codelight_core\hook_io.py"
    $socketServer = Join-Path $Root "companion\codelight_core\socket_server.py"

    $hookOk = (Test-Path $hookIo) -and
              (Select-String -LiteralPath $hookIo -Pattern 'WINDOWS_HOOK_PORT\s*=\s*8766' -Quiet)
    $serverOk = (Test-Path $socketServer) -and
                (Select-String -LiteralPath $socketServer -Pattern 'WINDOWS_HOOK_PORT' -Quiet)

    if (-not ($hookOk -and $serverOk)) {
        throw @"
This checkout does not contain the Windows hook transport patch.

Replace:
  companion\codelight_core\hook_io.py
  companion\codelight_core\socket_server.py

with the Windows-compatible versions included with these launcher scripts.
"@
    }
}

$python = Join-Path $Root ".venv\Scripts\python.exe"
$codelight = Join-Path $Root "companion\codelight.py"

if (-not (Test-Path -LiteralPath $python)) {
    throw "Python venv not found: $python. Create it with: py -m venv .venv"
}
if (-not (Test-Path -LiteralPath $codelight)) {
    throw "Codelight companion not found: $codelight"
}

Assert-WindowsHookTransport
Stop-ExistingCodelightListener

if ($Agents -match '(?i)(^|[, ]+)codex($|[, ]+)') {
    $codexExe = Find-CodexExecutable
    if (-not $codexExe) {
        throw "Codex executable not found. Install Codex or add codex.exe to PATH."
    }

    $codexDir = Split-Path -Parent $codexExe
    if (($env:PATH -split ';') -notcontains $codexDir) {
        $env:PATH = "$codexDir;$env:PATH"
    }
}

$argsList = @($codelight, "--name", $Name, "--agents", $Agents)
if ($CompanionVerbose) { $argsList += "--verbose" }

& $python @argsList
exit $LASTEXITCODE
