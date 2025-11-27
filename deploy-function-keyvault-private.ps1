#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates an Azure Function App with VNet integration to access a Private Endpoint-enabled Key Vault.
    Includes infrastructure deployment AND function code deployment in one script.

.DESCRIPTION
    This script sets up:
    1. Resource Group
    2. Virtual Network with subnets (Function integration + Private Endpoints)
    3. Storage Account with Managed Identity access
    4. Azure Function App (PowerShell) with VNet Integration
    5. Key Vault with Private Endpoint (public access disabled)
    6. Private DNS Zone for Key Vault
    7. Managed Identity with proper RBAC roles for Key Vault AND Storage
    8. Deploys the certificate rotation function code

    This is a SUPPORTED scenario - Azure Functions with VNet integration CAN access
    private endpoint-enabled Key Vaults.

.PARAMETER SkipCodeDeployment
    Skip the function code deployment step (useful for infrastructure-only updates)

.PARAMETER Suffix
    Unique suffix to append to all resource names (e.g., "888"). 
    If not provided, the script will prompt for it interactively.

.EXAMPLE
    .\deploy-function-keyvault-private.ps1
    # Will prompt for suffix interactively
    
.EXAMPLE
    .\deploy-function-keyvault-private.ps1 -Suffix "888"
    # Uses 888 as suffix for all resources

.EXAMPLE
    .\deploy-function-keyvault-private.ps1 -Suffix "888" -SkipCodeDeployment

.NOTES
    Author: GitHub Copilot
    Prerequisites: 
    - Azure CLI installed and logged in
    - Azure Functions Core Tools v4 (for code deployment)
#>

param(
    [string]$Suffix,
    [switch]$SkipCodeDeployment
)

# ============================================================================
# CONFIGURATION - Prompt for suffix if not provided
# ============================================================================
if ([string]::IsNullOrWhiteSpace($Suffix)) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "RESOURCE NAMING CONFIGURATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Enter a unique suffix for all Azure resources." -ForegroundColor Yellow
    Write-Host "This suffix will be appended to resource names to ensure uniqueness." -ForegroundColor Yellow
    Write-Host "Example: 888, dev, test, prod01" -ForegroundColor Gray
    Write-Host ""
    $Suffix = Read-Host "Enter suffix"
    
    if ([string]::IsNullOrWhiteSpace($Suffix)) {
        Write-Host "[ERROR] Suffix is required. Exiting." -ForegroundColor Red
        exit 1
    }
}

# Validate suffix (alphanumeric only, max 10 chars for storage account compatibility)
if ($Suffix -notmatch '^[a-zA-Z0-9]+$') {
    Write-Host "[ERROR] Suffix must contain only alphanumeric characters." -ForegroundColor Red
    exit 1
}

if ($Suffix.Length -gt 10) {
    Write-Host "[ERROR] Suffix must be 10 characters or less (for storage account naming)." -ForegroundColor Red
    exit 1
}

$UNIQUE_SUFFIX = $Suffix.ToLower()

$SUBSCRIPTION_ID = ""  # Leave empty to use current subscription
$RESOURCE_GROUP = "rg-function-keyvault-demo-$UNIQUE_SUFFIX"
$LOCATION = "centralus"

# Naming
$FUNCTION_APP_NAME = "func-kv-rotation-$UNIQUE_SUFFIX"
$STORAGE_ACCOUNT_NAME = "stfunckv$UNIQUE_SUFFIX"
$APP_SERVICE_PLAN_NAME = "asp-function-kv-$UNIQUE_SUFFIX"
$KEYVAULT_NAME = "kv-func-$UNIQUE_SUFFIX"
$VNET_NAME = "vnet-function-demo-$UNIQUE_SUFFIX"
$SUBNET_FUNCTION_NAME = "subnet-function-integration"
$SUBNET_PE_NAME = "subnet-private-endpoints"
$PRIVATE_ENDPOINT_NAME = "pe-keyvault-$UNIQUE_SUFFIX"
$PRIVATE_DNS_ZONE_NAME = "privatelink.vaultcore.azure.net"

# Script directory (for finding function code)
$SCRIPT_DIR = $PSScriptRoot
$FUNCTION_CODE_PATH = Join-Path $SCRIPT_DIR "CertRotationFunction"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "STEP: $Message" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

# ============================================================================
# ARCHITECTURE EXPLANATION
# ============================================================================
Write-Host @"

================================================================================
ARCHITECTURE: Azure Function with VNet Integration + Private Key Vault
================================================================================

This is a SUPPORTED scenario. Azure Functions with VNet Integration can access
private endpoint-enabled resources by routing traffic through the virtual network.

Architecture:
┌─────────────────────────────────────────────────────────────────────┐
│                          Virtual Network                            │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐ │
│  │  Function Integration   │    │  Private Endpoint Subnet        │ │
│  │  Subnet (/24)           │    │  (/24)                          │ │
│  │  ┌───────────────────┐  │    │  ┌───────────────────────────┐  │ │
│  │  │  Delegated to     │──│────│──│  Private Endpoint        │  │ │
│  │  │  Function App     │  │    │  │  (Key Vault)             │  │ │
│  │  └───────────────────┘  │    │  └───────────────────────────┘  │ │
│  └─────────────────────────┘    └─────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
         │                                      │
         │ VNet Integration                     │ Private Link
         │ (Outbound traffic)                   │
 ┌───────▼───────┐                      ┌───────▼───────┐
 │  Function App │                      │   Key Vault   │
 │  (PowerShell) │                      │  (Public Off) │
 │ (Managed ID)  │                      └───────────────┘
 └───────────────┘

Key Points:
• Function App uses VNet Integration (outbound traffic goes through VNet)
• Key Vault has Private Endpoint in the same VNet
• Private DNS Zone resolves Key Vault to private IP
• Function's Managed Identity has RBAC access to Key Vault AND Storage

================================================================================
"@ -ForegroundColor Yellow

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================
Write-Step "Checking Prerequisites"

# Check Azure CLI
if (-not (Test-CommandExists "az")) {
    Write-Err "Azure CLI is not installed. Please install it first: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
}

# Check Azure Functions Core Tools (only if code deployment is needed)
if (-not $SkipCodeDeployment) {
    if (-not (Test-CommandExists "func")) {
        Write-Err "Azure Functions Core Tools is not installed."
        Write-Host "Install with: npm install -g azure-functions-core-tools@4 --unsafe-perm true" -ForegroundColor Yellow
        Write-Host "Or use -SkipCodeDeployment to skip code deployment" -ForegroundColor Yellow
        exit 1
    }
    Write-Info "Azure Functions Core Tools: $(func --version)"
    
    # Check if function code exists
    if (-not (Test-Path $FUNCTION_CODE_PATH)) {
        Write-Err "Function code not found at: $FUNCTION_CODE_PATH"
        exit 1
    }
    Write-Info "Function code found at: $FUNCTION_CODE_PATH"
}

# Check Azure CLI login
Write-Step "Checking Azure CLI login status"
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Please login to Azure CLI first: az login" -ForegroundColor Red
    exit 1
}
Write-Info "Logged in as: $($account.user.name)"

# Set subscription if specified
if ($SUBSCRIPTION_ID) {
    az account set --subscription $SUBSCRIPTION_ID
    Write-Info "Using subscription: $SUBSCRIPTION_ID"
} else {
    Write-Info "Using current subscription: $($account.id)"
    $SUBSCRIPTION_ID = $account.id
}

# ============================================================================
# STEP 1: Create Resource Group
# ============================================================================
Write-Step "Creating Resource Group: $RESOURCE_GROUP in $LOCATION"
az group create `
    --name $RESOURCE_GROUP `
    --location $LOCATION `
    --output table

# ============================================================================
# STEP 2: Create Virtual Network with Subnets
# ============================================================================
Write-Step "Creating Virtual Network: $VNET_NAME"
az network vnet create `
    --resource-group $RESOURCE_GROUP `
    --name $VNET_NAME `
    --location $LOCATION `
    --address-prefixes "10.0.0.0/16" `
    --output table

Write-Info "Creating subnet for Function VNet Integration: $SUBNET_FUNCTION_NAME"
az network vnet subnet create `
    --resource-group $RESOURCE_GROUP `
    --vnet-name $VNET_NAME `
    --name $SUBNET_FUNCTION_NAME `
    --address-prefixes "10.0.1.0/24" `
    --delegations Microsoft.Web/serverFarms `
    --output table

Write-Info "Creating subnet for Private Endpoints: $SUBNET_PE_NAME"
az network vnet subnet create `
    --resource-group $RESOURCE_GROUP `
    --vnet-name $VNET_NAME `
    --name $SUBNET_PE_NAME `
    --address-prefixes "10.0.2.0/24" `
    --output table

# Disable private endpoint network policies on the PE subnet
az network vnet subnet update `
    --resource-group $RESOURCE_GROUP `
    --vnet-name $VNET_NAME `
    --name $SUBNET_PE_NAME `
    --private-endpoint-network-policies Disabled `
    --output none

Write-Info "Subnets created successfully"

# ============================================================================
# STEP 3: Create Storage Account for Function App
# ============================================================================
Write-Step "Creating Storage Account: $STORAGE_ACCOUNT_NAME"
az storage account create `
    --resource-group $RESOURCE_GROUP `
    --name $STORAGE_ACCOUNT_NAME `
    --location $LOCATION `
    --sku Standard_LRS `
    --kind StorageV2 `
    --output table

# Get Storage Account Resource ID
$storageAccountId = az storage account show `
    --resource-group $RESOURCE_GROUP `
    --name $STORAGE_ACCOUNT_NAME `
    --query "id" `
    --output tsv

Write-Info "Storage Account ID: $storageAccountId"

# ============================================================================
# STEP 4: Create App Service Plan (Premium for VNet Integration)
# ============================================================================
Write-Step "Creating App Service Plan: $APP_SERVICE_PLAN_NAME"
Write-Info "Using Premium V2 (P1V2) plan - required for VNet Integration"

az appservice plan create `
    --resource-group $RESOURCE_GROUP `
    --name $APP_SERVICE_PLAN_NAME `
    --location $LOCATION `
    --sku P1V2 `
    --output table

# ============================================================================
# STEP 5: Create Function App with PowerShell
# ============================================================================
Write-Step "Creating Function App: $FUNCTION_APP_NAME"
az functionapp create `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --storage-account $STORAGE_ACCOUNT_NAME `
    --plan $APP_SERVICE_PLAN_NAME `
    --runtime powershell `
    --runtime-version 7.4 `
    --functions-version 4 `
    --os-type Windows `
    --output table

Write-Info "Enabling System-Assigned Managed Identity"
az functionapp identity assign `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --output table

# Get the Function App's Managed Identity Principal ID
$functionIdentity = az functionapp identity show `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --query "principalId" `
    --output tsv

Write-Info "Function App Managed Identity Principal ID: $functionIdentity"

# ============================================================================
# STEP 6: Assign Storage Account RBAC Roles to Managed Identity
# ============================================================================
Write-Step "Assigning Storage Account roles to Function App Managed Identity"
Write-Info "This enables identity-based storage access (no connection strings needed)"

# Storage Blob Data Contributor - for function app content
Write-Info "Assigning Storage Blob Data Contributor role..."
az role assignment create `
    --role "Storage Blob Data Contributor" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $storageAccountId `
    --output none

# Storage Queue Data Contributor - for function triggers
Write-Info "Assigning Storage Queue Data Contributor role..."
az role assignment create `
    --role "Storage Queue Data Contributor" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $storageAccountId `
    --output none

# Storage Table Data Contributor - for function state
Write-Info "Assigning Storage Table Data Contributor role..."
az role assignment create `
    --role "Storage Table Data Contributor" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $storageAccountId `
    --output none

Write-Info "Storage RBAC roles assigned successfully"

# ============================================================================
# STEP 7: Enable VNet Integration for Function App
# ============================================================================
Write-Step "Enabling VNet Integration for Function App"

az functionapp vnet-integration add `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --vnet $VNET_NAME `
    --subnet $SUBNET_FUNCTION_NAME `
    --output table

Write-Info "VNet Integration enabled - Function can now access private endpoints"

# ============================================================================
# STEP 8: Configure Function App Settings (Identity-Based Storage)
# ============================================================================
Write-Step "Configuring Function App settings for Managed Identity"

# Remove the connection string and use identity-based access
Write-Info "Configuring identity-based storage access..."
az functionapp config appsettings set `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --settings `
        "AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME" `
        "AzureWebJobsStorage__credential=managedidentity" `
        "KEY_VAULT_NAME=$KEYVAULT_NAME" `
        "WEBSITE_VNET_ROUTE_ALL=1" `
        "WEBSITE_DNS_SERVER=168.63.129.16" `
    --output none

# Remove the connection string setting (identity-based takes precedence anyway, but cleaner)
Write-Info "Removing connection string to ensure managed identity is used..."
az functionapp config appsettings delete `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --setting-names "AzureWebJobsStorage" `
    --output none 2>$null

Write-Info "Function App configured with identity-based storage access"

# ============================================================================
# STEP 9: Create Key Vault with RBAC Authorization
# ============================================================================
Write-Step "Creating Key Vault: $KEYVAULT_NAME"
az keyvault create `
    --resource-group $RESOURCE_GROUP `
    --name $KEYVAULT_NAME `
    --location $LOCATION `
    --sku standard `
    --enable-rbac-authorization true `
    --output table

# Get Key Vault Resource ID
$keyVaultId = az keyvault show `
    --name $KEYVAULT_NAME `
    --resource-group $RESOURCE_GROUP `
    --query "id" `
    --output tsv

Write-Info "Key Vault Resource ID: $keyVaultId"

# ============================================================================
# STEP 10: Assign Key Vault RBAC Roles to Function App Managed Identity
# ============================================================================
Write-Step "Assigning Key Vault roles to Function App Managed Identity"

# Key Vault Secrets Officer - allows read/write to secrets
Write-Info "Assigning Key Vault Secrets Officer role..."
az role assignment create `
    --role "Key Vault Secrets Officer" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $keyVaultId `
    --output none

# Key Vault Certificates Officer - allows read/write to certificates
Write-Info "Assigning Key Vault Certificates Officer role..."
az role assignment create `
    --role "Key Vault Certificates Officer" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $keyVaultId `
    --output none

Write-Info "Key Vault RBAC roles assigned successfully"

# ============================================================================
# STEP 11: Create Private DNS Zone for Key Vault
# ============================================================================
Write-Step "Creating Private DNS Zone: $PRIVATE_DNS_ZONE_NAME"
az network private-dns zone create `
    --resource-group $RESOURCE_GROUP `
    --name $PRIVATE_DNS_ZONE_NAME `
    --output table

Write-Info "Linking Private DNS Zone to Virtual Network"
az network private-dns link vnet create `
    --resource-group $RESOURCE_GROUP `
    --zone-name $PRIVATE_DNS_ZONE_NAME `
    --name "link-$VNET_NAME" `
    --virtual-network $VNET_NAME `
    --registration-enabled false `
    --output table

# ============================================================================
# STEP 12: Create Private Endpoint for Key Vault
# ============================================================================
Write-Step "Creating Private Endpoint for Key Vault: $PRIVATE_ENDPOINT_NAME"
az network private-endpoint create `
    --resource-group $RESOURCE_GROUP `
    --name $PRIVATE_ENDPOINT_NAME `
    --location $LOCATION `
    --vnet-name $VNET_NAME `
    --subnet $SUBNET_PE_NAME `
    --private-connection-resource-id $keyVaultId `
    --group-id vault `
    --connection-name "connection-keyvault" `
    --output table

Write-Info "Creating DNS Zone Group for Private Endpoint"
az network private-endpoint dns-zone-group create `
    --resource-group $RESOURCE_GROUP `
    --endpoint-name $PRIVATE_ENDPOINT_NAME `
    --name "dns-zone-group" `
    --private-dns-zone $PRIVATE_DNS_ZONE_NAME `
    --zone-name "privatelink-vaultcore-azure-net" `
    --output table

# ============================================================================
# STEP 13: Disable Public Access on Key Vault
# ============================================================================
Write-Step "Disabling Public Access on Key Vault"
az keyvault update `
    --name $KEYVAULT_NAME `
    --resource-group $RESOURCE_GROUP `
    --default-action Deny `
    --public-network-access Disabled `
    --output table

Write-Info "Key Vault is now only accessible via Private Endpoint"

# ============================================================================
# STEP 14: Deploy Function Code
# ============================================================================
if (-not $SkipCodeDeployment) {
    Write-Step "Deploying Function Code"
    
    Write-Info "Waiting 30 seconds for RBAC role propagation..."
    Start-Sleep -Seconds 30
    
    Write-Info "Deploying from: $FUNCTION_CODE_PATH"
    Push-Location $FUNCTION_CODE_PATH
    
    try {
        # Deploy the function code
        func azure functionapp publish $FUNCTION_APP_NAME --powershell
        
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Function code deployed successfully!"
        } else {
            Write-Warn "Function deployment had issues. The sync triggers error is normal during first deployment."
            Write-Warn "The function will be available after managed dependencies are downloaded (2-5 minutes)."
        }
    }
    finally {
        Pop-Location
    }
    
    Write-Info "Waiting 90 seconds for function app to initialize managed dependencies..."
    Start-Sleep -Seconds 90
    
    # Try to get the function key
    Write-Info "Attempting to retrieve function key..."
    $maxRetries = 5
    $retryCount = 0
    $funcKey = $null
    
    while ($retryCount -lt $maxRetries -and -not $funcKey) {
        $funcKey = az functionapp function keys list `
            --resource-group $RESOURCE_GROUP `
            --name $FUNCTION_APP_NAME `
            --function-name "RotateCertificate" `
            --query "default" `
            --output tsv 2>$null
        
        if (-not $funcKey) {
            $retryCount++
            Write-Warn "Function key not available yet (attempt $retryCount/$maxRetries). Waiting 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
    
    if ($funcKey) {
        Write-Info "Function key retrieved successfully!"
    } else {
        Write-Warn "Could not retrieve function key. The function may still be initializing."
        Write-Warn "Try again in a few minutes using:"
        Write-Host "az functionapp function keys list --resource-group $RESOURCE_GROUP --name $FUNCTION_APP_NAME --function-name RotateCertificate --query default -o tsv"
    }
} else {
    Write-Step "Skipping Function Code Deployment"
    Write-Info "Use -SkipCodeDeployment:`$false or run: func azure functionapp publish $FUNCTION_APP_NAME --powershell"
    $funcKey = $null
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host @"

================================================================================
                           DEPLOYMENT COMPLETE!
================================================================================

Resources Created:
------------------
• Resource Group:      $RESOURCE_GROUP
• Function App:        $FUNCTION_APP_NAME (PowerShell 7.4)
• App Service Plan:    $APP_SERVICE_PLAN_NAME (Premium V2)
• Storage Account:     $STORAGE_ACCOUNT_NAME
• Key Vault:           $KEYVAULT_NAME (Private Endpoint, public access disabled)
• Virtual Network:     $VNET_NAME
• Private Endpoint:    $PRIVATE_ENDPOINT_NAME
• Private DNS Zone:    $PRIVATE_DNS_ZONE_NAME

Key Configuration:
------------------
• Function App has VNet Integration (outbound traffic routes through VNet)
• Function App uses System-Assigned Managed Identity
• Storage Account access: Identity-based (AzureWebJobsStorage__accountName)
• Managed Identity has these roles:
  - Storage Blob Data Contributor (on Storage Account)
  - Storage Queue Data Contributor (on Storage Account)
  - Storage Table Data Contributor (on Storage Account)
  - Key Vault Secrets Officer (on Key Vault)
  - Key Vault Certificates Officer (on Key Vault)
• Key Vault is accessible ONLY via Private Endpoint
• All Function traffic routed through VNet (WEBSITE_VNET_ROUTE_ALL=1)

Function App URL:
-----------------
https://$FUNCTION_APP_NAME.azurewebsites.net

"@ -ForegroundColor Green

if ($funcKey) {
    Write-Host @"
Function Key:
-------------
$funcKey

Test Commands:
--------------
# List all certificates
Invoke-RestMethod -Uri "https://$FUNCTION_APP_NAME.azurewebsites.net/api/RotateCertificate?code=$funcKey&action=list"

# Create a test certificate
Invoke-RestMethod -Uri "https://$FUNCTION_APP_NAME.azurewebsites.net/api/RotateCertificate?code=$funcKey&action=create&certificateName=test-cert" -Method Post

# Check certificate expiration status
Invoke-RestMethod -Uri "https://$FUNCTION_APP_NAME.azurewebsites.net/api/RotateCertificate?code=$funcKey&action=check"

"@ -ForegroundColor Yellow
} else {
    Write-Host @"
Next Steps:
-----------
1. Wait 2-5 minutes for managed dependencies to download

2. Get the function key:
   az functionapp function keys list --resource-group $RESOURCE_GROUP --name $FUNCTION_APP_NAME --function-name RotateCertificate --query default -o tsv

3. Test the function (see README.md for examples)

"@ -ForegroundColor Yellow
}

Write-Host @"
================================================================================
"@ -ForegroundColor Green

# Output resource IDs for reference
Write-Host "`nResource IDs for reference:" -ForegroundColor Cyan
Write-Host "Function App: https://$FUNCTION_APP_NAME.azurewebsites.net"
Write-Host "Key Vault ID: $keyVaultId"
Write-Host "Storage Account ID: $storageAccountId"
Write-Host "Managed Identity Principal ID: $functionIdentity"
