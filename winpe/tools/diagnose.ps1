$ErrorActionPreference = 'Continue'

$targetDirectory = 'C:\RecoveryPE'
try {
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
    $output = Join-Path $targetDirectory 'pe-diagnostics.txt'
}
catch {
    $output = 'X:\pe-diagnostics.txt'
}

function Add-Section {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Add-Content -LiteralPath $output -Value ''
    Add-Content -LiteralPath $output -Value "=== $Title ==="
    try {
        & $Command 2>&1 | Out-String -Width 240 |
            Add-Content -LiteralPath $output
    }
    catch {
        "ERROR: $($_.Exception.Message)" | Add-Content -LiteralPath $output
    }
}

Set-Content -LiteralPath $output -Encoding UTF8 -Value @(
    'MateBook E 2019 ARM64 Recovery PE diagnostics'
    "Generated: $(Get-Date -Format o)"
    "Computer: $env:COMPUTERNAME"
)

Add-Section 'Disks' { Get-Disk | Format-Table -AutoSize }
Add-Section 'Volumes' { Get-Volume | Sort-Object DriveLetter | Format-Table -AutoSize }
Add-Section 'Partitions' {
    Get-Partition | Sort-Object DiskNumber, PartitionNumber | Format-Table -AutoSize
}
Add-Section 'Storage and input devices' {
    & pnputil.exe /enum-devices /connected
}
Add-Section 'Qualcomm drivers' {
    & pnputil.exe /enum-drivers
}
Add-Section 'Storage driver services' {
    foreach ($serviceName in @('sdbus', 'sdstor', 'storufs', 'disk')) {
        "--- $serviceName ---"
        & sc.exe query $serviceName
    }
}
Add-Section 'ACPI QCOM2466 enum registry' {
    & reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\QCOM2466' /s
}
Add-Section 'Errors' {
    Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Level = 1, 2, 3
        StartTime = (Get-Date).AddMinutes(-30)
    } -ErrorAction SilentlyContinue |
        Select-Object -First 100 TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Format-List
}

Write-Host ''
Write-Host "Diagnostics written to $output"

$setupApi = 'X:\Windows\INF\setupapi.dev.log'
if (Test-Path -LiteralPath $setupApi) {
    Copy-Item -LiteralPath $setupApi -Destination (Join-Path $targetDirectory 'setupapi.dev.log') -Force
}
