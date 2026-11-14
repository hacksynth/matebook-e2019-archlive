[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host ">> $FilePath $($Arguments -join ' ')"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Add-WinPeOptionalComponent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$OptionalComponentsRoot,

        [Parameter(Mandatory = $true)]
        [string]$MountDirectory,

        [switch]$Required
    )

    $neutral = Join-Path $OptionalComponentsRoot "$Name.cab"
    $language = Join-Path $OptionalComponentsRoot "en-us\${Name}_en-us.cab"

    if (-not (Test-Path -LiteralPath $neutral)) {
        if ($Required) {
            throw "Required WinPE optional component not found: $neutral"
        }
        Write-Host "Optional component unavailable, skipping: $Name"
        return
    }

    Invoke-Native -FilePath dism.exe -Arguments @(
        "/Image:$MountDirectory",
        '/Add-Package',
        "/PackagePath:$neutral",
        '/LogPath:C:\Windows\Temp\WinPE-DISM.log'
    )

    if (Test-Path -LiteralPath $language) {
        Invoke-Native -FilePath dism.exe -Arguments @(
            "/Image:$MountDirectory",
            '/Add-Package',
            "/PackagePath:$language",
            '/LogPath:C:\Windows\Temp\WinPE-DISM.log'
        )
    }
}

$adkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit'
$winPeRoot = Join-Path $adkRoot 'Windows Preinstallation Environment'
$arm64MediaSource = Join-Path $winPeRoot 'arm64\media'
$oscdImgToolRoot = Join-Path $adkRoot 'Deployment Tools\amd64\Oscdimg'
$oscdImgRoot = Join-Path $adkRoot 'Deployment Tools\arm64\Oscdimg'
$dismRoot = Join-Path $adkRoot 'Deployment Tools\amd64\DISM'
$oscdImgExe = Join-Path $oscdImgToolRoot 'oscdimg.exe'
$efiBootImage = Join-Path $oscdImgRoot 'efisys.bin'

foreach ($requiredTool in @($arm64MediaSource, $oscdImgExe, $efiBootImage, $dismRoot)) {
    if (-not (Test-Path -LiteralPath $requiredTool)) {
        throw "Windows ADK WinPE file not found: $requiredTool"
    }
}

# The ADK installers do not propagate the Deployment and Imaging Tools
# environment into a fresh runner process.
$env:WinPERoot = $winPeRoot
$env:OSCDImgRoot = $oscdImgRoot
$env:DISM = $dismRoot

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This build must run from an elevated Windows process.'
}

$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$driverSource = Join-Path $RepositoryRoot 'winpe\drivers'
$startnetSource = Join-Path $RepositoryRoot 'winpe\startnet.cmd'
if (-not (Test-Path -LiteralPath $driverSource)) {
    throw "Driver tree not found: $driverSource"
}
if (-not (Test-Path -LiteralPath $startnetSource)) {
    throw "startnet.cmd not found: $startnetSource"
}

$runnerTemp = (Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$workRoot = Join-Path $runnerTemp 'matebook-winpe-arm64'
if (Test-Path -LiteralPath $workRoot) {
    $resolvedWorkRoot = (Resolve-Path -LiteralPath $workRoot).Path
    if (-not $resolvedWorkRoot.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected path: $resolvedWorkRoot"
    }
    Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $workRoot, $OutputDirectory | Out-Null
$adkEnvironment = 'set "WinPERoot={0}" && set "OSCDImgRoot={1}" && set "DISM={2}" && set "PATH={3};%PATH%"' -f `
    $winPeRoot, $oscdImgRoot, $dismRoot, $oscdImgToolRoot

# Avoid copype.cmd's architecture-specific DISM bootstrap. The installed
# arm64\media tree already contains the boot image and boot files we need.
Copy-Item -LiteralPath $arm64MediaSource -Destination (Join-Path $workRoot 'media') -Recurse -Force

$mediaDirectory = Join-Path $workRoot 'media'
$bootWim = Join-Path $mediaDirectory 'sources\boot.wim'
$mountDirectory = Join-Path $workRoot 'mount'
New-Item -ItemType Directory -Force -Path $mountDirectory | Out-Null
if (-not (Test-Path -LiteralPath $bootWim)) {
    $sourceWinPeWim = Get-ChildItem -LiteralPath $winPeRoot -Recurse -File -Filter 'winpe.wim' |
        Where-Object { $_.FullName -match '\\arm64\\' } |
        Select-Object -First 1
    if (-not $sourceWinPeWim) {
        throw "ARM64 WinPE base image not found under: $winPeRoot"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $bootWim -Parent) | Out-Null
    Copy-Item -LiteralPath $sourceWinPeWim.FullName -Destination $bootWim -Force
}
if (-not (Test-Path -LiteralPath $bootWim)) {
    throw "WinPE boot image not generated: $bootWim"
}

$mounted = $false
try {
    Invoke-Native -FilePath dism.exe -Arguments @(
        '/Mount-Image',
        "/ImageFile:$bootWim",
        '/Index:1',
        "/MountDir:$mountDirectory",
        '/LogPath:C:\Windows\Temp\WinPE-DISM.log'
    )
    $mounted = $true

    $optionalComponentsRoot = Join-Path $winPeRoot 'arm64\WinPE_OCs'
    $requiredComponents = @(
        'WinPE-WMI',
        'WinPE-NetFX',
        'WinPE-Scripting',
        'WinPE-PowerShell',
        'WinPE-DismCmdlets',
        'WinPE-StorageWMI'
    )
    foreach ($component in $requiredComponents) {
        Add-WinPeOptionalComponent -Name $component -OptionalComponentsRoot $optionalComponentsRoot `
            -MountDirectory $mountDirectory -Required
    }

    $optionalComponents = @(
        'WinPE-Fonts-Legacy',
        'WinPE-Font Support-ZH-CN',
        'WinPE-HTA',
        'WinPE-x64-Support'
    )
    foreach ($component in $optionalComponents) {
        Add-WinPeOptionalComponent -Name $component -OptionalComponentsRoot $optionalComponentsRoot `
            -MountDirectory $mountDirectory
    }

    $driverFailures = @()
    $driverInfs = @(Get-ChildItem -LiteralPath $driverSource -Recurse -File -Filter '*.inf' | Sort-Object FullName)
    foreach ($inf in $driverInfs) {
        Write-Host "Injecting ARM64 driver: $($inf.FullName)"
        & dism.exe "/Image:$mountDirectory" '/Add-Driver' "/Driver:$($inf.FullName)" `
            '/LogPath:C:\Windows\Temp\WinPE-DISM.log'
        if ($LASTEXITCODE -ne 0) {
            $driverFailures += $inf.FullName
        }
    }

    $driverStore = Join-Path $mountDirectory 'Windows\System32\DriverStore\FileRepository'
    $installedRepositories = @(
        Get-ChildItem -LiteralPath $driverStore -Directory -ErrorAction Stop |
            Select-Object -ExpandProperty Name
    )
    $requiredDrivers = @(
        'storufs.inf_arm64_*',
        'sdbus.inf_arm64_*',
        'sdstor.inf_arm64_*',
        'usbxhci.inf_arm64_*',
        'usbhub3.inf_arm64_*',
        'usbstor.inf_arm64_*',
        'hidi2c.inf_arm64_*',
        'qci2c850.inf_arm64_*',
        'qcgpio850.inf_arm64_*',
        'qcuart850.inf_arm64_*',
        'qcusbc850.inf_arm64_*'
    )
    foreach ($driverPattern in $requiredDrivers) {
        if (-not ($installedRepositories | Where-Object { $_ -like $driverPattern })) {
            throw "Required ARM64 driver was not injected: $driverPattern"
        }
    }

    Copy-Item -LiteralPath $startnetSource -Destination (Join-Path $mountDirectory 'Windows\System32\startnet.cmd') -Force
    $mediaDrivers = Join-Path $mediaDirectory 'Drivers'
    Copy-Item -LiteralPath $driverSource -Destination $mediaDrivers -Recurse -Force

    Invoke-Native -FilePath dism.exe -Arguments @(
        '/Unmount-Image',
        "/MountDir:$mountDirectory",
        '/Commit',
        '/LogPath:C:\Windows\Temp\WinPE-DISM.log'
    )
    $mounted = $false
}
finally {
    if ($mounted) {
        & dism.exe '/Unmount-Image' "/MountDir:$mountDirectory" '/Discard' 2>$null
    }
}

$outputIso = Join-Path $OutputDirectory 'MateBook-E2019-ARM64-Recovery.iso'
if (Test-Path -LiteralPath $outputIso) {
    Remove-Item -LiteralPath $outputIso -Force
}
$bootData = '1#pEF,e,b"{0}"' -f $efiBootImage
Invoke-Native -FilePath $oscdImgExe -Arguments @(
    '-m',
    '-o',
    '-u2',
    '-udfver102',
    "-bootdata:$bootData",
    '-lMATEBOOK_PE',
    $mediaDirectory,
    $outputIso
)

$hash = Get-FileHash -LiteralPath $outputIso -Algorithm SHA256
$sizeMiB = [math]::Round((Get-Item -LiteralPath $outputIso).Length / 1MB, 2)
$failedDriverCount = @($driverFailures).Count
$info = @"
MateBook E 2019 ARM64 Recovery PE
Architecture: ARM64
ADK: 10.1.26100.9457
WinPE: 10.1.26100.9457
ISO size: $sizeMiB MiB
SHA256: $($hash.Hash)
Driver INF count: $($driverInfs.Count)
Driver injection failures: $failedDriverCount
SD/UFS drivers: storufs, sdbus, sdstor
USB/HID drivers: usbxhci, usbhub3, usbstor, hidi2c
Driver tree on media: X:\Drivers
"@
$info | Set-Content -LiteralPath (Join-Path $OutputDirectory 'BUILD-INFO.txt') -Encoding UTF8
$info

if ($driverFailures.Count -gt 0) {
    $driverFailures | Set-Content -LiteralPath (Join-Path $OutputDirectory 'DRIVER-WARNINGS.txt') -Encoding UTF8
    Write-Warning "$($driverFailures.Count) optional driver packages were rejected; see DRIVER-WARNINGS.txt"
}
