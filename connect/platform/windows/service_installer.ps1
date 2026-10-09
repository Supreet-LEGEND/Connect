# Connect Background Transfer Service Installer
# Run as Administrator

param(
    [string]$ServiceName = "ConnectTransferService",
    [string]$DisplayName = "Connect Background Transfer Service",
    [string]$Description = "Background file transfer service for Connect app",
    [string]$BinaryPath = "C:\Program Files\Connect\connect-background-service.exe",
    [string]$User = "LocalSystem",
    [switch]$StartOnBoot = $true
)

Write-Host "Installing Connect Background Transfer Service..." -ForegroundColor Green

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Check if binary exists
if (-not (Test-Path $BinaryPath)) {
    Write-Error "Service binary not found at: $BinaryPath"
    Write-Host "Please build the Rust service first: cargo build --release --manifest-path platform/windows/background_service/Cargo.toml"
    Write-Host "Then copy the binary to: $BinaryPath"
    exit 1
}

# Stop and remove existing service if present
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Stopping existing service..." -ForegroundColor Yellow
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    
    Write-Host "Removing existing service..." -ForegroundColor Yellow
    sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
}

# Create the service
Write-Host "Creating service..." -ForegroundColor Green
$service = New-Service -Name $ServiceName -BinaryPathName $BinaryPath -DisplayName $DisplayName -Description $Description -StartupType Automatic -ErrorAction Stop

if ($StartOnBoot) {
    Set-Service -Name $ServiceName -StartupType Automatic
}

# Configure service recovery (restart on failure)
Write-Host "Configuring service recovery..." -ForegroundColor Green
sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/60000 | Out-Null

# Set service description
sc.exe description $ServiceName $Description | Out-Null

# Start the service
Write-Host "Starting service..." -ForegroundColor Green
Start-Service -Name $ServiceName -ErrorAction SilentlyContinue

# Verify service is running
Start-Sleep -Seconds 3
$serviceStatus = Get-Service -Name $ServiceName
if ($serviceStatus.Status -eq 'Running') {
    Write-Host "Service installed and started successfully!" -ForegroundColor Green
} else {
    Write-Warning "Service installed but not running. Check Event Viewer for details."
}

Write-Host ""
Write-Host "Service Details:" -ForegroundColor Cyan
Write-Host "  Name: $ServiceName"
Write-Host "  Display Name: $DisplayName"
Write-Host "  Binary: $BinaryPath"
Write-Host "  Startup: Automatic"
Write-Host ""
Write-Host "To uninstall, run: .\uninstall_service.ps1" -ForegroundColor Yellow