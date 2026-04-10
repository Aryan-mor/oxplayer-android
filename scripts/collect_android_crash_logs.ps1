param(
    [string]$DeviceId,
    [string]$PackageName = 'de.aryanmo.oxplayer.debug'
)

$ErrorActionPreference = 'Stop'

function Get-ConnectedDevices {
    $lines = & adb devices
    $devices = @()

    foreach ($line in $lines) {
        if ($line -match '^(?<id>[^\s]+)\s+device$') {
            $serial = $Matches['id']
            $model = (& adb -s $serial shell getprop ro.product.model).Trim()
            $devices += [pscustomobject]@{
                Id = $serial
                Model = if ($model) { $model } else { 'Unknown device' }
            }
        }
    }

    return $devices
}

function Select-TargetDevice {
    param([string]$RequestedDeviceId)

    $devices = @(Get-ConnectedDevices)
    if (-not $devices -or $devices.Count -eq 0) {
        throw 'No Android devices are connected.'
    }

    if ($RequestedDeviceId) {
        $selected = $devices | Where-Object { $_.Id -eq $RequestedDeviceId } | Select-Object -First 1
        if (-not $selected) {
            throw "Requested device '$RequestedDeviceId' is not connected."
        }
        return $selected
    }

    if ($devices.Count -eq 1) {
        return $devices[0]
    }

    Write-Host 'Connected Android devices:'
    for ($index = 0; $index -lt $devices.Count; $index++) {
        $device = $devices[$index]
        Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $device.Model, $device.Id)
    }

    while ($true) {
        $choice = Read-Host 'Select a device number'
        $parsedChoice = 0
        if ([int]::TryParse($choice, [ref]$parsedChoice)) {
            $selectedIndex = $parsedChoice - 1
            if ($selectedIndex -ge 0 -and $selectedIndex -lt $devices.Count) {
                return $devices[$selectedIndex]
            }
        }
        Write-Host 'Invalid selection. Enter one of the listed numbers.'
    }
}

function Resolve-InstalledPackageName {
    param(
        [string]$SelectedDeviceId,
        [string]$RequestedPackageName
    )

    $candidatePackages = @(
        $RequestedPackageName,
        'de.aryanmo.oxplayer.debug',
        'de.aryanmo.oxplayer'
    ) | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique

    $installedPackages = (& adb -s $SelectedDeviceId shell pm list packages) | ForEach-Object {
        $_.ToString().Trim().Replace('package:', '')
    }

    foreach ($candidate in $candidatePackages) {
        if ($installedPackages -contains $candidate) {
            return $candidate
        }
    }

    $matchingPackage = $installedPackages | Where-Object { $_ -like 'de.aryanmo.oxplayer*' } | Select-Object -First 1
    if ($matchingPackage) {
        return $matchingPackage
    }

    return $RequestedPackageName
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$selectedDevice = Select-TargetDevice -RequestedDeviceId $DeviceId
$resolvedPackageName = Resolve-InstalledPackageName -SelectedDeviceId $selectedDevice.Id -RequestedPackageName $PackageName
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputDir = Join-Path $projectRoot ("build\crash-logs\$timestamp")
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$crashBufferPath = Join-Path $outputDir 'logcat-crash.txt'
$runtimePath = Join-Path $outputDir 'logcat-runtime.txt'
$packagePath = Join-Path $outputDir 'logcat-package.txt'
$tombstoneListPath = Join-Path $outputDir 'tombstones.txt'

$packagePidOutput = & adb -s $selectedDevice.Id shell pidof $resolvedPackageName
$packagePid = if ($null -ne $packagePidOutput) { ($packagePidOutput | Out-String).Trim() } else { '' }

& adb -s $selectedDevice.Id logcat -b crash -d -t 300 | Out-File -FilePath $crashBufferPath -Encoding utf8
& adb -s $selectedDevice.Id logcat -d -t 500 AndroidRuntime:E libc:F flutter:E DartVM:E DEBUG:F '*:S' | Out-File -FilePath $runtimePath -Encoding utf8
if ($packagePid) {
    & adb -s $selectedDevice.Id logcat --pid $packagePid -d -t 500 | Out-File -FilePath $packagePath -Encoding utf8
}
else {
    & adb -s $selectedDevice.Id logcat -d -t 500 | Select-String -Pattern $resolvedPackageName | Out-File -FilePath $packagePath -Encoding utf8
}
& adb -s $selectedDevice.Id shell ls -t /data/tombstones | Out-File -FilePath $tombstoneListPath -Encoding utf8

$latestTombstone = (& adb -s $selectedDevice.Id shell ls -t /data/tombstones | Select-Object -First 1).Trim()
if ($latestTombstone) {
    $tombstoneOutPath = Join-Path $outputDir $latestTombstone
    & adb -s $selectedDevice.Id shell cat "/data/tombstones/$latestTombstone" | Out-File -FilePath $tombstoneOutPath -Encoding utf8
}

Write-Host ''
Write-Host ("Crash diagnostics saved to: {0}" -f $outputDir)
Write-Host ("Device: {0} ({1})" -f $selectedDevice.Model, $selectedDevice.Id)
Write-Host ("Package: {0}" -f $resolvedPackageName)
Write-Host 'Files:'
Write-Host (" - {0}" -f $crashBufferPath)
Write-Host (" - {0}" -f $runtimePath)
Write-Host (" - {0}" -f $packagePath)
Write-Host (" - {0}" -f $tombstoneListPath)
if ($latestTombstone) {
    Write-Host (" - {0}" -f (Join-Path $outputDir $latestTombstone))
}