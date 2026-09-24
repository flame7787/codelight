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

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Python = Join-Path $Root ".venv\Scripts\pythonw.exe"
$Codelight = Join-Path $Root "companion\codelight.py"

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

function Stop-OtherTrayInstances {
    $selfPid = $PID
    $others = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $selfPid -and
            $_.CommandLine -match '(?i)codelight-tray\.ps1'
        }

    foreach ($other in $others) {
        try {
            Stop-Process -Id $other.ProcessId -Force -ErrorAction Stop
        }
        catch { }
    }
}

function Stop-ExistingCodelightListener {
    $listeners = @(Get-NetTCPConnection -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)

    foreach ($listener in $listeners) {
        $ownerPid = $listener.OwningProcess
        if (-not $ownerPid) { continue }

        $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
        if (-not $owner) { continue }

        if ($owner.CommandLine -match '(?i)codelight\.py') {
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
        [System.Windows.Forms.MessageBox]::Show(
            "This checkout does not contain the Windows hook transport patch.`n`nReplace companion\codelight_core\hook_io.py and socket_server.py with the Windows-compatible versions included with these scripts.",
            "Codelight"
        ) | Out-Null
        exit 1
    }
}

if (-not (Test-Path -LiteralPath $Python)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Python virtual environment not found.`n`nExpected:`n$Python`n`nCreate it with: py -m venv .venv",
        "Codelight"
    ) | Out-Null
    exit 1
}

if (-not (Test-Path -LiteralPath $Codelight)) {
    [System.Windows.Forms.MessageBox]::Show(
        "companion\codelight.py was not found next to this script.",
        "Codelight"
    ) | Out-Null
    exit 1
}

Assert-WindowsHookTransport
Stop-OtherTrayInstances
Stop-ExistingCodelightListener

if ($Agents -match '(?i)(^|[, ]+)codex($|[, ]+)') {
    $CodexExe = Find-CodexExecutable
    if (-not $CodexExe) {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not locate a Codex executable. Install Codex or make codex.exe available in PATH.",
            "Codelight"
        ) | Out-Null
        exit 1
    }

    $CodexDir = Split-Path -Parent $CodexExe
    if (($env:PATH -split ';') -notcontains $CodexDir) {
        $env:PATH = "$CodexDir;$env:PATH"
    }
}

$script:Companion = $null

function Start-Companion {
    if ($script:Companion -and -not $script:Companion.HasExited) { return }

    $argumentParts = @(
        "`"$Codelight`"",
        "--name", "`"$Name`"",
        "--agents", "`"$Agents`""
    )
    if ($CompanionVerbose) { $argumentParts += "--verbose" }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Python
    $info.Arguments = ($argumentParts -join " ")
    $info.WorkingDirectory = $Root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $false
    $info.RedirectStandardError = $false

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $script:Companion = $process
}

function Stop-Companion {
    if ($script:Companion -and -not $script:Companion.HasExited) {
        try {
            $script:Companion.Kill()
            [void]$script:Companion.WaitForExit(3000)
        }
        catch { }
    }
    $script:Companion = $null
}

function Restart-Companion {
    Stop-Companion
    Start-Sleep -Milliseconds 500
    Stop-ExistingCodelightListener
    Start-Companion
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Information
$script:Tray.Text = "Codelight Companion"
$script:Tray.Visible = $true

$Menu = New-Object System.Windows.Forms.ContextMenuStrip

$Status = New-Object System.Windows.Forms.ToolStripMenuItem
$Status.Text = "Codelight: starting..."
$Status.Enabled = $false
[void]$Menu.Items.Add($Status)

$NameItem = New-Object System.Windows.Forms.ToolStripMenuItem
$NameItem.Text = "Name: $Name"
$NameItem.Enabled = $false
[void]$Menu.Items.Add($NameItem)

[void]$Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$Restart = New-Object System.Windows.Forms.ToolStripMenuItem
$Restart.Text = "Restart Companion"
$Restart.Add_Click({ Restart-Companion })
[void]$Menu.Items.Add($Restart)

$OpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$OpenFolder.Text = "Open Codelight Folder"
$OpenFolder.Add_Click({ Start-Process explorer.exe $Root })
[void]$Menu.Items.Add($OpenFolder)

$Exit = New-Object System.Windows.Forms.ToolStripMenuItem
$Exit.Text = "Exit"
$Exit.Add_Click({
    Stop-Companion
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
[void]$Menu.Items.Add($Exit)

$script:Tray.ContextMenuStrip = $Menu
$script:Tray.Add_DoubleClick({ Start-Process explorer.exe $Root })

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 2000
$Timer.Add_Tick({
    if ($script:Companion -and -not $script:Companion.HasExited) {
        $Status.Text = "Codelight: Running"
        $script:Tray.Text = "Codelight Companion - Running"
    }
    else {
        $Status.Text = "Codelight: Stopped"
        $script:Tray.Text = "Codelight Companion - Stopped"
    }
})
$Timer.Start()

Start-Companion
$script:Tray.ShowBalloonTip(
    1500,
    "Codelight",
    "Companion started as '$Name'.",
    [System.Windows.Forms.ToolTipIcon]::Info
)
[System.Windows.Forms.Application]::Run()
