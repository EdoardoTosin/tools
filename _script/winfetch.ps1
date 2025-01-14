################################################################################
# winfetch.ps1
# A PowerShell script that displays system information in a format similar to
# Neofetch.
# This script includes provides details about the operating system, hostname,
# user, uptime, screen resolution, CPU(s), GPU(s), memory, and local disks.
#
# Copyright (c) 2024-25 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

$asciiArt = @"
        .__        _____       __         .__     
__  _  _|__| _____/ ____\_____/  |_  ____ |  |__  
\ \/ \/ /  |/    \   __\/ __ \   __\/ ___\|  |  \ 
 \     /|  |   |  \  | \  ___/|  | \  \___|   Y  \
  \/\_/ |__|___|  /__|  \___  >__|  \___  >___|  /
                \/          \/          \/     \/ 
"@

# Initialize default values
$resolution = "N/A"
$hostname = $env:COMPUTERNAME
$user = $env:USERNAME
$uptime = "N/A"
$memoryString = "N/A"
$cpus = @()
$gpus = @()
$disks = @()

# Get Operating System information
try {
    $os = Get-WmiObject -Class Win32_OperatingSystem
    $uptime = (Get-Date) - $os.ConvertToDateTime($os.LastBootUpTime)
} catch {
    Write-Warning "Failed to retrieve OS information."
}

# Get CPU information
try {
    $cpus = Get-WmiObject -Class Win32_Processor
} catch {
    Write-Warning "Failed to retrieve CPU information."
}

# Get GPU information and screen resolution
try {
    $gpus = Get-WmiObject -Class Win32_VideoController
    if ($gpus) {
        $gpuInfo = $gpus | Select-Object -First 1
        if ($gpuInfo) {
            $horizontalRes = $gpuInfo.CurrentHorizontalResolution
            $verticalRes = $gpuInfo.CurrentVerticalResolution
            if ($horizontalRes -and $verticalRes) {
                $resolution = "$horizontalRes x $verticalRes"
            }
        }
    }
} catch {
    Write-Warning "Failed to retrieve GPU or resolution information."
}

# Get memory information
try {
    $memory = (Get-WmiObject -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
    $memoryString = "{0:N2} GB" -f $memory
} catch {
    Write-Warning "Failed to retrieve memory information."
}

# Get disk information (local disks only)
try {
    $disks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3"  # Local disks only
} catch {
    Write-Warning "Failed to retrieve disk information."
}

# Display ASCII Art logo
Write-Host -ForegroundColor Cyan "$asciiArt`n"

# Display OS details
if ($os) {
    Write-Host -ForegroundColor Green "OS:            " -NoNewline; Write-Host -ForegroundColor White "$($os.Caption) $($os.Version)"
} else {
    Write-Host -ForegroundColor Green "OS:            " -NoNewline; Write-Host -ForegroundColor White "N/A"
}

# Display hostname and user
Write-Host -ForegroundColor Green "Host:          " -NoNewline; Write-Host -ForegroundColor White "$hostname"
Write-Host -ForegroundColor Green "User:          " -NoNewline; Write-Host -ForegroundColor White "$user"

# Display uptime
if ($uptime -ne "N/A") {
    Write-Host -ForegroundColor Green "Uptime:        " -NoNewline; Write-Host -ForegroundColor White "$($uptime.Days) days $($uptime.Hours) hours $($uptime.Minutes) minutes"
} else {
    Write-Host -ForegroundColor Green "Uptime:        " -NoNewline; Write-Host -ForegroundColor White "N/A"
}

# Display resolution
Write-Host -ForegroundColor Green "Resolution:    " -NoNewline; Write-Host -ForegroundColor White "$resolution"

# Display CPU(s) details
if ($cpus) {
    $cpuIndex = 0
    foreach ($cpu in $cpus) {
        Write-Host -ForegroundColor Green "CPU ${cpuIndex}:         " -NoNewline; Write-Host -ForegroundColor White "$($cpu.Name)"
        $cpuIndex++
    }
} else {
    Write-Host -ForegroundColor Green "CPU:           " -NoNewline; Write-Host -ForegroundColor White "N/A"
}

# Display GPU(s) details
if ($gpus) {
    $gpuIndex = 0
    foreach ($gpu in $gpus) {
        Write-Host -ForegroundColor Green "GPU ${gpuIndex}:         " -NoNewline; Write-Host -ForegroundColor White "$($gpu.Name)"
        $gpuIndex++
    }
} else {
    Write-Host -ForegroundColor Green "GPU:           " -NoNewline; Write-Host -ForegroundColor White "N/A"
}

# Display memory information
Write-Host -ForegroundColor Green "Memory:        " -NoNewline; Write-Host -ForegroundColor White "$memoryString"

# Display disk(s) information
if ($disks) {
    foreach ($disk in $disks) {
        $diskSize = "{0:N2} GB" -f ($disk.Size / 1GB)
        $diskFreeSpace = "{0:N2} GB" -f ($disk.FreeSpace / 1GB)
        Write-Host -ForegroundColor Green "Disk ($($disk.DeviceID)):     " -NoNewline; Write-Host -ForegroundColor White "$diskSize (Free: $diskFreeSpace)"
    }
} else {
    Write-Host -ForegroundColor Green "Disk:          " -NoNewline; Write-Host -ForegroundColor White "N/A"
}
