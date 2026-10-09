# Connect Background Transfer Service Uninstaller
# Run as Administrator

param(
    [string]$ServiceName = "ConnectTransferService"
)

Write-Host "Uninstalling Connect Background Transfer Service..." -ForegroundColor Green

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Stop and remove service
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Stopping service..." -ForegroundColor Yellow
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    
    Write-Host "Removing service..." -ForegroundColor Yellow
    sc.exe delete $ServiceName | Out-Null
    
    Write-Host "Service uninstalled successfully!" -ForegroundColor Green
} else {
    Write-Warning "Service not found: $ServiceName"
}