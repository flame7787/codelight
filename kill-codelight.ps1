#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$ListOnly
)

$matches = Get-CimInstance Win32_Process |
    Where-Object {
        $_.CommandLine -and (
            $_.CommandLine -match '(?i)(^|[\\/])codelight\.py(?:\s|"|$)' -or
            $_.CommandLine -match '(?i)(^|[\\/])codelight-tray\.ps1(?:\s|"|$)'
        )
    }

if (-not $matches) {
    Write-Host "No Codelight companion/tray processes found."
    exit 0
}

$matches | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize

if ($ListOnly) { exit 0 }

foreach ($process in $matches) {
    if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId) ($($process.Name))", "Stop Codelight process")) {
        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not stop PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}
