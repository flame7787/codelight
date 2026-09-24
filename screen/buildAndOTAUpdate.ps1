#requires -Version 5.1
<#
.SYNOPSIS
    Build codelight firmware and flash it over the air from Windows.

.DESCRIPTION
    Windows/PowerShell port of buildAndOTAUpdate.sh.

    Auto-detects the updater on the device:
      - codelight firmware        -> synchronous updater on :81
      - codelight bootstrap       -> single upload via /flash, eboot does the copy
      - GeekMagic KR_SDP          -> two-step install (bootstrap -> codelight)
      - GeekMagic stock (legacy)  -> ESP8266HTTPUpdateServer on :80/update

    Windows requirements:
      - PlatformIO CLI ("pio") in PATH
      - curl.exe (included with modern Windows 10/11)
      - Wi-Fi managed by Windows WLAN AutoConfig if automatic AP switching is needed

.EXAMPLE
    .\buildAndOTAUpdate.ps1

.EXAMPLE
    .\buildAndOTAUpdate.ps1 192.168.1.50

.EXAMPLE
    .\buildAndOTAUpdate.ps1 192.168.4.1 -WifiSsid "MyNet" -WifiPassword "s3cr3t"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$HostName = "codelight-screen.local",

    [string]$WifiSsid = "",

    [string]$WifiPassword = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $PSScriptRoot) {
    throw "Unable to determine the script directory."
}

# Allow this script to live either in the repository root or in screen/.
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "platformio.ini")) {
    $ScreenRoot = $PSScriptRoot
}
elseif (Test-Path -LiteralPath (Join-Path $PSScriptRoot "screen\platformio.ini")) {
    $ScreenRoot = Join-Path $PSScriptRoot "screen"
}
else {
    throw "Could not locate screen\platformio.ini relative to this script."
}
Set-Location $ScreenRoot

$FirmwareBin = ".pio\build\geekmagic_ultra\firmware.bin"
$BootstrapBin = ".pio\build\bootstrap\firmware.bin"
$SetupSsid = "codelight-screen-setup"

function Write-Step {
    param([string]$Message)
    Write-Host "-- $Message"
}

function Require-Command {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Resolve-PlatformIO {
    $command = Get-Command pio.exe -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command pio -ErrorAction SilentlyContinue }
    if ($command) { return $command.Source }

    $candidate = Join-Path $env:USERPROFILE ".platformio\penv\Scripts\pio.exe"
    if (Test-Path -LiteralPath $candidate) { return $candidate }

    throw "PlatformIO CLI was not found in PATH or at '$candidate'."
}

function Get-FileSize {
    param([string]$Path)

    return (Get-Item -LiteralPath $Path).Length
}

function Invoke-CurlText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & curl.exe @Arguments 2>$null
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $text = ""
    if ($null -ne $output) {
        $text = ($output | Out-String).TrimEnd()
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Text     = $text
    }
}

function Test-HttpUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSeconds = 10
    )

    $result = Invoke-CurlText @(
        "-s", "-f",
        "--max-time", "$TimeoutSeconds",
        "-o", "NUL",
        $Url
    )

    return ($result.ExitCode -eq 0)
}

function Get-HttpText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSeconds = 10,
        [switch]$Compressed
    )

    $args = @("-s", "-f", "--max-time", "$TimeoutSeconds")
    if ($Compressed) {
        $args += "--compressed"
    }
    $args += $Url

    $result = Invoke-CurlText $args
    if ($result.ExitCode -ne 0) {
        return ""
    }

    return $result.Text
}

function Test-TextContains {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }

    return [regex]::IsMatch(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Get-CurrentWifiProfile {
    # netsh output is localized. This parser is reliable on English Windows.
    # If it cannot determine the current profile, automatic reconnection is skipped.
    try {
        $lines = & netsh.exe wlan show interfaces 2>$null
        foreach ($line in $lines) {
            if ($line -match '^\s*Profile\s*:\s*(.+?)\s*$') {
                $name = $Matches[1].Trim()
                if ($name -and $name -ne "<not connected>") {
                    return $name
                }
            }
        }
    }
    catch {
    }

    return ""
}

function Test-WifiSsidVisible {
    param([Parameter(Mandatory = $true)][string]$Ssid)

    try {
        $output = (& netsh.exe wlan show networks mode=bssid 2>$null | Out-String)
        return ($output -match [regex]::Escape($Ssid))
    }
    catch {
        return $false
    }
}

function Ensure-OpenWifiProfile {
    param([Parameter(Mandatory = $true)][string]$Ssid)

    # Windows needs a WLAN profile before netsh can join an open AP.
    $escaped = [System.Security.SecurityElement]::Escape($Ssid)
    $profilePath = Join-Path $env:TEMP "codelight-open-wifi.xml"

    $xmlLines = @(
        '<?xml version="1.0"?>',
        '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">',
        "  <name>$escaped</name>",
        '  <SSIDConfig>',
        '    <SSID>',
        "      <name>$escaped</name>",
        '    </SSID>',
        '  </SSIDConfig>',
        '  <connectionType>ESS</connectionType>',
        '  <connectionMode>manual</connectionMode>',
        '  <MSM>',
        '    <security>',
        '      <authEncryption>',
        '        <authentication>open</authentication>',
        '        <encryption>none</encryption>',
        '        <useOneX>false</useOneX>',
        '      </authEncryption>',
        '    </security>',
        '  </MSM>',
        '</WLANProfile>'
    )
    $xml = $xmlLines -join "`r`n"

    [System.IO.File]::WriteAllText(
        $profilePath,
        $xml,
        [System.Text.Encoding]::UTF8
    )

    try {
        & netsh.exe wlan add profile filename="$profilePath" user=current *> $null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return $true
    }
    finally {
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    }
}

function Connect-WifiProfile {
    param([Parameter(Mandatory = $true)][string]$ProfileName)

    & netsh.exe wlan connect name="$ProfileName" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Connect-SetupWifi {
    if (-not (Ensure-OpenWifiProfile $SetupSsid)) {
        Write-Warning "Could not create a Windows WLAN profile for '$SetupSsid'."
        return $false
    }

    & netsh.exe wlan connect name="$SetupSsid" ssid="$SetupSsid" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-ForSetupAp {
    param([int]$Attempts = 20)

    Write-Host -NoNewline "-- Waiting for '$SetupSsid' AP (up to $($Attempts * 2) s) "
    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Seconds 2

        if (Test-WifiSsidVisible $SetupSsid) {
            Write-Host " found"
            return $true
        }

        Write-Host -NoNewline "."
    }

    Write-Host
    return $false
}

function Wait-ForUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$Attempts = 30,
        [int]$DelaySeconds = 2,
        [int]$TimeoutSeconds = 10,
        [string]$Label = ""
    )

    if ($Label) {
        Write-Host -NoNewline "-- $Label "
    }

    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Seconds $DelaySeconds

        if (Test-HttpUrl -Url $Url -TimeoutSeconds $TimeoutSeconds) {
            if ($Label) {
                Write-Host " ok"
            }
            return $true
        }

        if ($Label) {
            Write-Host -NoNewline "."
        }
    }

    if ($Label) {
        Write-Host
    }

    return $false
}

function Push-WifiConfig {
    $previousProfile = Get-CurrentWifiProfile

    if (-not (Wait-ForSetupAp -Attempts 20)) {
        Write-Warning "'$SetupSsid' did not appear. Configure manually at http://192.168.4.1"
        return $false
    }

    Write-Step "Connecting to $SetupSsid..."
    if (-not (Connect-SetupWifi)) {
        Write-Warning "Windows could not connect to '$SetupSsid'. Configure manually at http://192.168.4.1"
        return $false
    }

    if (-not (Wait-ForUrl `
        -Url "http://192.168.4.1/" `
        -Attempts 15 `
        -DelaySeconds 2 `
        -TimeoutSeconds 10 `
        -Label "Waiting for config API")) {

        Write-Warning "Could not reach 192.168.4.1. Configure manually at http://192.168.4.1"

        if ($previousProfile) {
            [void](Connect-WifiProfile $previousProfile)
        }

        return $false
    }

    $wifiJson = @{
        wifi = @(
            @{
                ssid     = $WifiSsid
                password = $WifiPassword
            }
        )
    } | ConvertTo-Json -Compress -Depth 4

    Write-Step "Pushing WiFi config (ssid: $WifiSsid)..."
    [void](Invoke-CurlText @(
        "-s",
        "--max-time", "15",
        "-H", "Content-Type: application/json",
        "--data-raw", $wifiJson,
        "http://192.168.4.1/api/config"
    ))

    Write-Step "Triggering reboot..."
    [void](Invoke-CurlText @(
        "-s",
        "--max-time", "10",
        "-X", "POST",
        "http://192.168.4.1/api/reboot"
    ))

    if ($previousProfile) {
        Write-Step "Reconnecting to '$previousProfile'..."
        [void](Connect-WifiProfile $previousProfile)
        Start-Sleep -Seconds 3
    }

    if (Wait-ForUrl `
        -Url "http://codelight-screen.local/" `
        -Attempts 30 `
        -DelaySeconds 2 `
        -TimeoutSeconds 10 `
        -Label "Waiting for codelight on codelight-screen.local") {

        Write-Step "Done - http://codelight-screen.local/debug"
        return $true
    }

    Write-Warning "Device did not appear as codelight-screen.local within 60 s - check it manually."
    return $false
}

function Upload-FormFile {
    param(
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 300,
        [string]$RemoteFileName = ""
    )

    $fullPath = (Resolve-Path -LiteralPath $FilePath).Path

    if ($RemoteFileName) {
        $form = "$FieldName=@$fullPath;filename=$RemoteFileName"
    }
    else {
        $form = "$FieldName=@$fullPath"
    }

    return Invoke-CurlText @(
        "-s",
        "--max-time", "$TimeoutSeconds",
        "-F", $form,
        $Url
    )
}

function New-GzipFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $sourceFull = (Resolve-Path -LiteralPath $SourcePath).Path
    $destFull = [System.IO.Path]::GetFullPath($DestinationPath)

    $input = [System.IO.File]::OpenRead($sourceFull)
    try {
        $output = [System.IO.File]::Create($destFull)
        try {
            $gzip = [System.IO.Compression.GZipStream]::new(
                $output,
                [System.IO.Compression.CompressionMode]::Compress
            )
            try {
                $input.CopyTo($gzip)
            }
            finally {
                $gzip.Dispose()
            }
        }
        finally {
            $output.Dispose()
        }
    }
    finally {
        $input.Dispose()
    }

    return $destFull
}

# -- Requirements and build ----------------------------------------------------

$PioCommand = Resolve-PlatformIO
Require-Command "curl.exe"
Require-Command "netsh.exe"

Write-Step "Building firmware..."
& $PioCommand run
if ($LASTEXITCODE -ne 0) {
    throw "PlatformIO build failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $FirmwareBin)) {
    throw "Build completed, but firmware was not found at '$FirmwareBin'."
}

# -- Bootstrap path -------------------------------------------------------------
# Device is already running the codelight bootstrap.
# If 192.168.4.1 is requested and unreachable, try joining the setup AP.

$previousProfile = ""
$bootstrapPage = Get-HttpText -Url "http://$HostName/" -TimeoutSeconds 10

if (($HostName -eq "192.168.4.1") -and [string]::IsNullOrEmpty($bootstrapPage)) {
    $previousProfile = Get-CurrentWifiProfile

    Write-Step "192.168.4.1 not reachable - connecting to '$SetupSsid'..."
    [void](Connect-SetupWifi)

    Write-Host -NoNewline "-- Waiting for bootstrap at 192.168.4.1 "
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 2
        $bootstrapPage = Get-HttpText -Url "http://$HostName/" -TimeoutSeconds 10

        if (-not [string]::IsNullOrEmpty($bootstrapPage)) {
            Write-Host " ok"
            break
        }

        Write-Host -NoNewline "."
    }
    Write-Host
}

if (Test-TextContains -Text $bootstrapPage -Pattern "bootstrap") {
    Write-Step "Bootstrap detected on $HostName"

    if (-not (Test-TextContains -Text $bootstrapPage -Pattern "bootstrap v8")) {
        Write-Step "Outdated bootstrap - upgrading to v8 first..."

        if (-not (Test-Path -LiteralPath $BootstrapBin)) {
            throw "Bootstrap binary not found at '$BootstrapBin'."
        }

        $result = Upload-FormFile `
            -FieldName "fw" `
            -FilePath $BootstrapBin `
            -Url "http://$HostName/flash" `
            -TimeoutSeconds 180

        if (Test-TextContains -Text $result.Text -Pattern "copying firmware") {
            Write-Step "Bootstrap upgrade: copying to flash, rebooting..."
        }
        elseif ([string]::IsNullOrEmpty($result.Text)) {
            Write-Host "   (connection dropped - normal)"
        }
        else {
            throw "Bootstrap upgrade failed: $($result.Text)"
        }

        if (-not $previousProfile) {
            $previousProfile = Get-CurrentWifiProfile
        }

        Start-Sleep -Seconds 3
        Write-Step "Connecting to $SetupSsid for v8 bootstrap..."
        [void](Connect-SetupWifi)

        $HostName = "192.168.4.1"
        $bootstrapPage = ""

        Write-Host -NoNewline "-- Waiting for bootstrap v8 at 192.168.4.1 "
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Seconds 2
            $bootstrapPage = Get-HttpText -Url "http://$HostName/" -TimeoutSeconds 10

            if (Test-TextContains -Text $bootstrapPage -Pattern "bootstrap v8") {
                Write-Host " ok"
                break
            }

            Write-Host -NoNewline "."
        }
        Write-Host

        if (-not (Test-TextContains -Text $bootstrapPage -Pattern "bootstrap v8")) {
            throw "Bootstrap v8 did not appear - upgrade may have failed."
        }

        Write-Step "Bootstrap upgraded to v8"
    }

    Write-Step "Uploading $(Get-FileSize $FirmwareBin) bytes to $HostName..."

    $result = Upload-FormFile `
        -FieldName "fw" `
        -FilePath $FirmwareBin `
        -Url "http://$HostName/flash" `
        -TimeoutSeconds 300

    if (Test-TextContains -Text $result.Text -Pattern "copying firmware") {
        Write-Step "Firmware staged, device rebooting..."
    }
    elseif ([string]::IsNullOrEmpty($result.Text)) {
        Write-Host "   (connection dropped during reboot - this is normal)"
    }
    else {
        throw "Unexpected response: $($result.Text)"
    }

    if ($previousProfile) {
        Write-Step "Reconnecting to '$previousProfile'..."
        [void](Connect-WifiProfile $previousProfile)
        Start-Sleep -Seconds 3
    }

    if (Wait-ForUrl `
        -Url "http://codelight-screen.local/" `
        -Attempts 30 `
        -DelaySeconds 2 `
        -TimeoutSeconds 10 `
        -Label "Waiting for codelight on codelight-screen.local") {

        Write-Step "Done - http://codelight-screen.local/debug"
        exit 0
    }

    Write-Step "Did not appear as codelight-screen.local - first-run AP mode."

    if ($WifiSsid) {
        [void](Push-WifiConfig)
    }
    else {
        Write-Host "   Connect to '$SetupSsid' and open http://192.168.4.1"
    }

    exit 0
}

# -- Codelight path (:81 synchronous updater) ----------------------------------

$syncOk = $false
for ($i = 0; $i -lt 3; $i++) {
    if (Test-HttpUrl -Url "http://$HostName`:81/update" -TimeoutSeconds 5) {
        $syncOk = $true
        break
    }

    Start-Sleep -Seconds 2
}

if ($syncOk) {
    Write-Step "Synchronous updater found on :81"

    $ok = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result = Upload-FormFile `
            -FieldName "firmware" `
            -FilePath $FirmwareBin `
            -Url "http://$HostName`:81/update" `
            -TimeoutSeconds 300

        if (Test-TextContains -Text $result.Text -Pattern "Update Success") {
            $ok = $true
            break
        }

        $displayResponse = $result.Text
        if ([string]::IsNullOrEmpty($displayResponse)) {
            $displayResponse = "connection dropped"
        }

        Write-Warning "attempt $attempt`: $displayResponse"
        Start-Sleep -Seconds 3
    }

    if (-not $ok) {
        throw "Giving up after 3 attempts."
    }

    Write-Step "Uploaded $(Get-FileSize $FirmwareBin) bytes, device is rebooting"

    if (Wait-ForUrl `
        -Url "http://$HostName/" `
        -Attempts 30 `
        -DelaySeconds 2 `
        -TimeoutSeconds 2 `
        -Label "Waiting for http://$HostName to come back") {

        Write-Step "Done - device is up: http://$HostName/debug"
        exit 0
    }

    Write-Warning "Device did not respond within 60 s - check it manually."
    exit 1
}

# -- KR_SDP path (two-step install) --------------------------------------------

Write-Step "Probing http://$HostName/update_ota ..."

$tempProbe = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($tempProbe, "test")

    $fullProbePath = (Resolve-Path -LiteralPath $tempProbe).Path
    $probeResult = Invoke-CurlText @(
        "-s",
        "-o", "NUL",
        "-w", "%{http_code}",
        "-F", "update=@$fullProbePath",
        "http://$HostName/update_ota"
    )

    $probeCode = $probeResult.Text.Trim()
}
finally {
    Remove-Item -LiteralPath $tempProbe -Force -ErrorAction SilentlyContinue
}

if ($probeCode -and ($probeCode -ne "404")) {
    Write-Step "KR_SDP stock firmware detected - running two-step install"

    if (-not (Test-Path -LiteralPath $BootstrapBin)) {
        throw "Bootstrap binary not found at '$BootstrapBin'."
    }

    Write-Step "Step 1/2: flashing bootstrap..."

    $otaResult = Upload-FormFile `
        -FieldName "update" `
        -FilePath $BootstrapBin `
        -RemoteFileName "KR_SDP_bootstrap.bin" `
        -Url "http://$HostName/update_ota" `
        -TimeoutSeconds 60

    $otaText = $otaResult.Text
    if ([string]::IsNullOrEmpty($otaText)) {
        $otaText = "(empty)"
    }
    Write-Host "   /update_ota response: $otaText"

    if (-not (Wait-ForSetupAp -Attempts 20)) {
        throw "'$SetupSsid' AP did not appear - bootstrap flash may have failed."
    }

    Write-Step "Step 2/2: connecting to bootstrap AP..."
    $previousProfile = Get-CurrentWifiProfile

    if (-not (Connect-SetupWifi)) {
        throw "Windows could not connect to '$SetupSsid'."
    }

    if (-not (Wait-ForUrl `
        -Url "http://192.168.4.1/" `
        -Attempts 20 `
        -DelaySeconds 2 `
        -TimeoutSeconds 10 `
        -Label "Waiting for bootstrap to respond")) {

        throw "Bootstrap did not respond at 192.168.4.1."
    }

    Write-Step "Uploading codelight firmware ($(Get-FileSize $FirmwareBin) bytes) to 192.168.4.1..."

    $result = Upload-FormFile `
        -FieldName "fw" `
        -FilePath $FirmwareBin `
        -Url "http://192.168.4.1/flash" `
        -TimeoutSeconds 300

    if ($previousProfile) {
        Write-Step "Reconnecting to '$previousProfile'..."
        [void](Connect-WifiProfile $previousProfile)
        Start-Sleep -Seconds 3
    }

    if (Test-TextContains -Text $result.Text -Pattern "copying firmware") {
        Write-Step "Firmware staged, device rebooting..."
    }
    elseif ([string]::IsNullOrEmpty($result.Text)) {
        Write-Host "   (connection dropped during reboot - this is normal)"
    }
    else {
        throw "Unexpected response: $($result.Text)"
    }

    if (Wait-ForUrl `
        -Url "http://codelight-screen.local/" `
        -Attempts 30 `
        -DelaySeconds 2 `
        -TimeoutSeconds 2 `
        -Label "Waiting for codelight to come up on codelight-screen.local") {

        Write-Step "Done - codelight is up: http://codelight-screen.local/debug"
        exit 0
    }

    Write-Step "Device did not appear as codelight-screen.local within 60 s."

    if ($WifiSsid) {
        [void](Push-WifiConfig)
    }
    else {
        Write-Host "   Connect to '$SetupSsid' WiFi and open http://192.168.4.1 to configure."
    }

    exit 0
}

# -- Legacy stock firmware path ------------------------------------------------

Write-Step "Probing http://$HostName/update ..."

$page = Get-HttpText `
    -Url "http://$HostName/update" `
    -TimeoutSeconds 10 `
    -Compressed

if ([string]::IsNullOrEmpty($page)) {
    throw "Cannot reach http://$HostName/update"
}

if (-not (Test-TextContains `
    -Text $page `
    -Pattern 'name\s*=\s*[''"]firmware[''"]|multipart/form-data')) {

    Write-Error "No known updater found on $HostName."
    Write-Host "A device on legacy codelight firmware (<= v1.0.11) can be updated"
    Write-Host "once via its browser page at http://$HostName/update."
    exit 1
}

Write-Step "Stock firmware updater detected (ESP8266HTTPUpdateServer)"

# Stock uses a large-filesystem flash layout leaving only ~520 KB of OTA
# staging space. Compress the firmware with .NET instead of requiring gzip.exe.
$gzipPath = "$FirmwareBin.gz"
Write-Step "Compressing firmware for legacy OTA..."
[void](New-GzipFile -SourcePath $FirmwareBin -DestinationPath $gzipPath)

$result = Upload-FormFile `
    -FieldName "firmware" `
    -FilePath $gzipPath `
    -Url "http://$HostName/update" `
    -TimeoutSeconds 180

if (-not (Test-TextContains -Text $result.Text -Pattern "Update Success")) {
    $displayResponse = $result.Text
    if ([string]::IsNullOrEmpty($displayResponse)) {
        $displayResponse = "connection dropped"
    }

    throw "Unexpected response: $displayResponse"
}

Write-Step "Uploaded $(Get-FileSize $gzipPath) bytes, device is rebooting"

if ($WifiSsid) {
    [void](Push-WifiConfig)
}
else {
    Write-Step "First flash: connect to the '$SetupSsid' WiFi AP and"
    Write-Host "   open http://192.168.4.1 to configure. See README.md."
}

exit 0
