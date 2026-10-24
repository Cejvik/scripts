#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [string]$VMName = 'server1',
    [string]$GPUName = 'AMD Radeon(TM) Graphics',
    [ValidateRange(1, 30)]
    [int]$ShutdownTimeoutMinutes = 5
)

$ErrorActionPreference = 'Stop'

$repositoryCommit = '2353d36325e18c759ca3888e6591e18e5f371011'
$repositoryBaseUrl = "https://raw.githubusercontent.com/jamesstringer90/Easy-GPU-PV/$repositoryCommit"
$workingDirectory = Join-Path $env:TEMP ("Easy-GPU-PV-" + [guid]::NewGuid().ToString('N'))
$updaterPath = Join-Path $workingDirectory 'Update-VMGpuPartitionDriver.ps1'
$modulePath = Join-Path $workingDirectory 'Add-VMGpuPartitionAdapterFiles.psm1'

$gpu = Get-PnpDevice -Class Display -ErrorAction Stop |
    Where-Object { $_.FriendlyName -eq $GPUName -and $_.Status -eq 'OK' } |
    Select-Object -First 1

if (-not $gpu) {
    throw "GPU '$GPUName' was not found in OK state on this host."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -notin @('Running', 'Off')) {
    throw "VM '$VMName' is in state '$($vm.State)'. Shut it down manually and rerun this script."
}

New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
Invoke-WebRequest -Uri "$repositoryBaseUrl/Update-VMGpuPartitionDriver.ps1" -OutFile $updaterPath
Invoke-WebRequest -Uri "$repositoryBaseUrl/Add-VMGpuPartitionAdapterFiles.psm1" -OutFile $modulePath
Unblock-File -Path @($updaterPath, $modulePath)

if ($vm.State -eq 'Running') {
    Write-Host "Requesting a graceful shutdown of '$VMName'..."
    Stop-VM -Name $VMName -Confirm:$false

    $deadline = (Get-Date).AddMinutes($ShutdownTimeoutMinutes)
    do {
        Start-Sleep -Seconds 2
        $state = (Get-VM -Name $VMName).State
    } while ($state -ne 'Off' -and (Get-Date) -lt $deadline)

    if ($state -ne 'Off') {
        throw "VM '$VMName' did not shut down within $ShutdownTimeoutMinutes minutes. It was not force-stopped."
    }
}

$updateCompleted = $false
try {
    Write-Host "Copying host GPU driver files into '$VMName'..."
    & $updaterPath -VMName $VMName -GPUName $GPUName -Hostname $env:COMPUTERNAME
    $updateCompleted = $true
}
finally {
    if ($updateCompleted) {
        $state = (Get-VM -Name $VMName).State
        if ($state -eq 'Off') {
            Write-Host "Starting '$VMName'..."
            Start-VM -Name $VMName
        }
    }
    else {
        Write-Warning "Driver update did not complete. '$VMName' is being left off; inspect the error before starting it."
    }
}

Write-Host 'Driver files copied successfully.'