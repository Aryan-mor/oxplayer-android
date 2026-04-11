param(
    [ValidateSet('attach', 'reinstall')]
    [string]$Mode = 'attach',
    [string]$DeviceId,
    [switch]$SkipAttach
)

$ErrorActionPreference = 'Stop'

$packageName = 'de.aryanmo.oxplayer.debug'
$projectRoot = Split-Path -Parent $PSScriptRoot
$apkOutputDir = Join-Path $projectRoot 'build\app\outputs\flutter-apk'

function Get-DebugApkPath {
    param([string]$TargetAbi)

    return (Join-Path $apkOutputDir ("app-{0}-debug.apk" -f $TargetAbi))
}

function Get-BuildInputs {
    $relativePaths = @(
        'pubspec.yaml',
        'assets\env\default.env',
        'assets\env\default.env.example'
    )

    $paths = @()
    foreach ($relativePath in $relativePaths) {
        $fullPath = Join-Path $projectRoot $relativePath
        if (Test-Path $fullPath) {
            $paths += $fullPath
        }
    }

    return $paths
}

function Test-DebugBuildIsStale {
    param([string]$TargetAbi)

    $apkPath = Get-DebugApkPath -TargetAbi $TargetAbi
    if (-not (Test-Path $apkPath)) {
        return $true
    }

    $apkTimestampUtc = (Get-Item $apkPath).LastWriteTimeUtc
    foreach ($inputPath in Get-BuildInputs) {
        if ((Get-Item $inputPath).LastWriteTimeUtc -gt $apkTimestampUtc) {
            Write-Host ("Detected newer build input: {0}" -f $inputPath)
            return $true
        }
    }

    return $false
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $AllowFailure -and $exitCode -ne 0) {
        $argText = if ($Arguments.Count -gt 0) { " " + ($Arguments -join ' ') } else { '' }
        throw "Command failed with exit code ${exitCode}: $FilePath$argText"
    }

    return $exitCode
}

function Get-ConnectedDevices {
    $lines = & adb devices
    $devices = @()

    foreach ($line in $lines) {
        if ($line -match '^(?<id>[^\s]+)\s+device$') {
            $serial = $Matches['id']
            $model = (& adb -s $serial shell getprop ro.product.model).Trim()
            $abiList = (& adb -s $serial shell getprop ro.product.cpu.abilist).Trim()
            $abi = (& adb -s $serial shell getprop ro.product.cpu.abi).Trim()
            $devices += [pscustomobject]@{
                Id = $serial
                Model = if ($model) { $model } else { 'Unknown device' }
                AbiList = if ($abiList) { $abiList } else { $abi }
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
        Write-Host ("[{0}] {1} ({2}) - {3}" -f ($index + 1), $device.Model, $device.Id, $device.AbiList)
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

function Resolve-TargetAbi {
    param([string]$AbiList)

    $knownAbis = @('x86_64', 'arm64-v8a', 'armeabi-v7a', 'x86')
    foreach ($abi in $knownAbis) {
        if ($AbiList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $abi }) {
            return $abi
        }
    }

    throw "Unsupported device ABI list: $AbiList"
}

function Build-DebugApks {
    Push-Location $projectRoot
    try {
        Invoke-CheckedCommand -FilePath 'flutter' -Arguments @('build', 'apk', '--debug', '--split-per-abi')
    }
    finally {
        Pop-Location
    }
}

function Install-And-Launch {
    param(
        [string]$SelectedDeviceId,
        [string]$TargetAbi
    )

    $apkPath = Get-DebugApkPath -TargetAbi $TargetAbi
    if (-not (Test-Path $apkPath)) {
        throw "Expected APK not found: $apkPath"
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $installOutput = & adb -s $SelectedDeviceId install -r $apkPath 2>&1
    $installExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($installExitCode -ne 0) {
        $installText = ($installOutput | Out-String)
        if ($installText -match 'INSTALL_FAILED_INSUFFICIENT_STORAGE') {
            Write-Host 'Install failed due to insufficient storage. Retrying with keep-data uninstall fallback...'
            Invoke-CheckedCommand -FilePath 'adb' -Arguments @('-s', $SelectedDeviceId, 'shell', 'pm', 'uninstall', '-k', '--user', '0', $packageName) -AllowFailure | Out-Null
            Invoke-CheckedCommand -FilePath 'adb' -Arguments @('-s', $SelectedDeviceId, 'install', $apkPath) | Out-Null
        }
        else {
            throw "Command failed with exit code ${installExitCode}: adb -s $SelectedDeviceId install -r $apkPath`n$installText"
        }
    }
    Invoke-CheckedCommand -FilePath 'adb' -Arguments @('-s', $SelectedDeviceId, 'shell', 'monkey', '-p', $packageName, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
}

function Launch-ExistingInstall {
    param([string]$SelectedDeviceId)

    $installedPath = (& adb -s $SelectedDeviceId shell pm path $packageName).Trim()
    if (-not $installedPath) {
        throw "Package '$packageName' is not installed on device '$SelectedDeviceId'. Use reinstall mode first."
    }

    Invoke-CheckedCommand -FilePath 'adb' -Arguments @('-s', $SelectedDeviceId, 'shell', 'monkey', '-p', $packageName, '-c', 'android.intent.category.LAUNCHER', '1') | Out-Null
}

$selectedDevice = Select-TargetDevice -RequestedDeviceId $DeviceId
$targetAbi = Resolve-TargetAbi -AbiList $selectedDevice.AbiList

Write-Host ("Using device: {0} ({1})" -f $selectedDevice.Model, $selectedDevice.Id)
Write-Host ("Resolved APK ABI: {0}" -f $targetAbi)

switch ($Mode) {
    'reinstall' {
        Build-DebugApks
        Install-And-Launch -SelectedDeviceId $selectedDevice.Id -TargetAbi $targetAbi
    }
    'attach' {
        if (Test-DebugBuildIsStale -TargetAbi $targetAbi) {
            Write-Host 'Local debug APK is missing or stale. Rebuilding and reinstalling before attach...'
            Build-DebugApks
            Install-And-Launch -SelectedDeviceId $selectedDevice.Id -TargetAbi $targetAbi
        }
        else {
            Launch-ExistingInstall -SelectedDeviceId $selectedDevice.Id
        }
    }
}

if (-not $SkipAttach) {
    Push-Location $projectRoot
    try {
        Invoke-CheckedCommand -FilePath 'flutter' -Arguments @('attach', '-d', $selectedDevice.Id)
    }
    finally {
        Pop-Location
    }
}