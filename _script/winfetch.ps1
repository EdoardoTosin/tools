################################################################################
# winfetch.ps1
# A PowerShell script that displays system information in a format similar to
# Neofetch.
# This script includes provides details about the operating system, hostname,
# user, uptime, screen resolution, CPU(s), GPU(s), memory, and local disks.
#
# Copyright (c) 2024 Edoardo Tosin
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

# Get System Information
$os = Get-WmiObject -Class Win32_OperatingSystem
$cpus = Get-WmiObject -Class Win32_Processor
$gpus = Get-WmiObject -Class Win32_VideoController
$memory = (Get-WmiObject -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB
$disks = Get-WmiObject -Class Win32_LogicalDisk -Filter "DriveType=3"  # Filter for local disks only
$uptime = (Get-Date) - $os.ConvertToDateTime($os.LastBootUpTime)
$hostname = $env:COMPUTERNAME
$user = $env:USERNAME
$resolution = (Get-WmiObject -Class Win32_VideoController | Select-Object -First 1).CurrentHorizontalResolution.ToString() + "x" + (Get-WmiObject -Class Win32_VideoController | Select-Object -First 1).CurrentVerticalResolution.ToString()

# Display colored Output
Write-Host -ForegroundColor Cyan "$asciiArt`n"

Write-Host -ForegroundColor Green "OS:            " -NoNewline; Write-Host -ForegroundColor White "$($os.Caption) $($os.Version)"
Write-Host -ForegroundColor Green "Host:          " -NoNewline; Write-Host -ForegroundColor White "$hostname"
Write-Host -ForegroundColor Green "User:          " -NoNewline; Write-Host -ForegroundColor White "$user"
Write-Host -ForegroundColor Green "Uptime:        " -NoNewline; Write-Host -ForegroundColor White "$($uptime.Days) days $($uptime.Hours) hours $($uptime.Minutes) minutes"
Write-Host -ForegroundColor Green "Resolution:    " -NoNewline; Write-Host -ForegroundColor White "$resolution"

# Display CPU(s)
$cpuIndex = 0
foreach ($cpu in $cpus) {
    Write-Host -ForegroundColor Green "CPU ${cpuIndex}:         " -NoNewline; Write-Host -ForegroundColor White "$($cpu.Name)"
    $cpuIndex++
}

# Display GPU(s)
$gpuIndex = 0
foreach ($gpu in $gpus) {
    Write-Host -ForegroundColor Green "GPU ${gpuIndex}:         " -NoNewline; Write-Host -ForegroundColor White "$($gpu.Name)"
    $gpuIndex++
}

# Display Memory
$memoryString = "{0:N2} GB" -f $memory
Write-Host -ForegroundColor Green "Memory:        " -NoNewline; Write-Host -ForegroundColor White "$memoryString"

# Display Disk(s)
foreach ($disk in $disks) {
    $diskSize = "{0:N2} GB" -f ($disk.Size / 1GB)
    $diskFreeSpace = "{0:N2} GB" -f ($disk.FreeSpace / 1GB)
    Write-Host -ForegroundColor Green "Disk ($($disk.DeviceID)):     " -NoNewline; Write-Host -ForegroundColor White "$diskSize (Free: $diskFreeSpace)"
}
