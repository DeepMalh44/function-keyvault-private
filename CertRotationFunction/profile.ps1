# Profile.ps1
# This script runs at Function App startup
# Use it to perform initialization tasks like connecting to Azure

# Authenticate using the Function App's Managed Identity
if ($env:MSI_SECRET) {
    # Running in Azure with Managed Identity
    Write-Host "Connecting to Azure using Managed Identity..."
    try {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Host "Successfully connected to Azure using Managed Identity"
    }
    catch {
        Write-Error "Failed to connect to Azure: $_"
    }
}
else {
    Write-Host "Running locally - Managed Identity not available"
    Write-Host "Use 'Connect-AzAccount' to authenticate for local development"
}
