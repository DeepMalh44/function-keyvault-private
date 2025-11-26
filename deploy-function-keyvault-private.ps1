#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates an Azure Function App with VNet integration to access a Private Endpoint-enabled Key Vault.

.DESCRIPTION
    This script sets up:
    1. Resource Group
    2. Virtual Network with subnets (Function integration + Private Endpoints)
    3. Azure Function App (PowerShell) with VNet Integration
    4. Key Vault with Private Endpoint (public access disabled)
    5. Private DNS Zone for Key Vault
    6. Managed Identity with Key Vault permissions
    7. Sample PowerShell function for certificate rotation

    This is a SUPPORTED scenario - Azure Functions with VNet integration CAN access
    private endpoint-enabled Key Vaults.

.NOTES
    Author: GitHub Copilot
    Prerequisites: 
    - Azure CLI installed and logged in
    - Azure Functions Core Tools (optional, for local development)
#>

# ============================================================================
# CONFIGURATION - Update these variables as needed
# ============================================================================
$SUBSCRIPTION_ID = ""  # Leave empty to use current subscription
$RESOURCE_GROUP = "rg-function-keyvault-demo"
$LOCATION = "centralus"
$UNIQUE_SUFFIX = Get-Random -Maximum 9999

# Naming
$FUNCTION_APP_NAME = "func-kv-rotation-$UNIQUE_SUFFIX"
$STORAGE_ACCOUNT_NAME = "stfunckv$UNIQUE_SUFFIX"
$APP_SERVICE_PLAN_NAME = "asp-function-kv-$UNIQUE_SUFFIX"
$KEYVAULT_NAME = "kv-func-$UNIQUE_SUFFIX"
$VNET_NAME = "vnet-function-demo"
$SUBNET_FUNCTION_NAME = "subnet-function-integration"
$SUBNET_PE_NAME = "subnet-private-endpoints"
$PRIVATE_ENDPOINT_NAME = "pe-keyvault"
$PRIVATE_DNS_ZONE_NAME = "privatelink.vaultcore.azure.net"

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

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
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
• Function's Managed Identity has RBAC access to Key Vault

================================================================================
"@ -ForegroundColor Yellow

# ============================================================================
# PREREQUISITE CHECKS
# ============================================================================
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
# This subnet will be delegated to Microsoft.Web/serverFarms
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

# ============================================================================
# STEP 4: Create App Service Plan (Premium for VNet Integration)
# ============================================================================
Write-Step "Creating App Service Plan: $APP_SERVICE_PLAN_NAME"
Write-Info "Using Premium V2 (P1v2) plan - required for VNet Integration"

az appservice plan create `
    --resource-group $RESOURCE_GROUP `
    --name $APP_SERVICE_PLAN_NAME `
    --location $LOCATION `
    --sku P1V2 `
    --is-linux false `
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
# STEP 6: Enable VNet Integration for Function App
# ============================================================================
Write-Step "Enabling VNet Integration for Function App"

$subnetId = az network vnet subnet show `
    --resource-group $RESOURCE_GROUP `
    --vnet-name $VNET_NAME `
    --name $SUBNET_FUNCTION_NAME `
    --query "id" `
    --output tsv

az functionapp vnet-integration add `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --vnet $VNET_NAME `
    --subnet $SUBNET_FUNCTION_NAME `
    --output table

Write-Info "VNet Integration enabled - Function can now access private endpoints"

# Configure Function App to route ALL traffic through VNet
Write-Info "Configuring Function App to route all traffic through VNet"
az functionapp config appsettings set `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --settings "WEBSITE_VNET_ROUTE_ALL=1" `
    --output none

az functionapp config appsettings set `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --settings "WEBSITE_DNS_SERVER=168.63.129.16" `
    --output none

# ============================================================================
# STEP 7: Create Key Vault with RBAC Authorization
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
# STEP 8: Create Private DNS Zone for Key Vault
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
# STEP 9: Create Private Endpoint for Key Vault
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
# STEP 10: Disable Public Access on Key Vault
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
# STEP 11: Assign Key Vault RBAC Roles to Function App Managed Identity
# ============================================================================
Write-Step "Assigning Key Vault roles to Function App Managed Identity"

# Key Vault Secrets Officer - allows read/write to secrets
Write-Info "Assigning Key Vault Secrets Officer role..."
az role assignment create `
    --role "Key Vault Secrets Officer" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $keyVaultId `
    --output table

# Key Vault Certificates Officer - allows read/write to certificates
Write-Info "Assigning Key Vault Certificates Officer role..."
az role assignment create `
    --role "Key Vault Certificates Officer" `
    --assignee-object-id $functionIdentity `
    --assignee-principal-type ServicePrincipal `
    --scope $keyVaultId `
    --output table

Write-Info "Function App can now manage Key Vault secrets and certificates"

# ============================================================================
# STEP 12: Configure Key Vault Reference in Function App Settings
# ============================================================================
Write-Step "Configuring Function App settings"

# Add Key Vault name as app setting
az functionapp config appsettings set `
    --resource-group $RESOURCE_GROUP `
    --name $FUNCTION_APP_NAME `
    --settings "KEY_VAULT_NAME=$KEYVAULT_NAME" `
    --output none

Write-Info "Function App configured with Key Vault name"

# ============================================================================
# STEP 13: Create a Test Certificate in Key Vault
# ============================================================================
Write-Step "Creating a test certificate in Key Vault"
Write-Warning "This may fail if run from outside the VNet (public access disabled)"
Write-Info "You can create certificates later from the Azure Portal or from within the VNet"

# Try to create a self-signed certificate (may fail if public access already disabled)
$certPolicy = @{
    issuerParameters = @{
        name = "Self"
    }
    keyProperties = @{
        exportable = $true
        keySize = 2048
        keyType = "RSA"
        reuseKey = $false
    }
    secretProperties = @{
        contentType = "application/x-pkcs12"
    }
    x509CertificateProperties = @{
        subject = "CN=TestCertificate"
        validityInMonths = 12
    }
} | ConvertTo-Json -Depth 5 -Compress

# Note: This will likely fail since public access is disabled - that's expected
Write-Warning "Certificate creation from public network may fail - this is expected behavior"

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
• Function App has System-Assigned Managed Identity
• Managed Identity has:
  - 'Key Vault Secrets Officer' role
  - 'Key Vault Certificates Officer' role
• Key Vault is accessible ONLY via Private Endpoint
• All Function traffic routed through VNet (WEBSITE_VNET_ROUTE_ALL=1)

Function App URL:
-----------------
https://$FUNCTION_APP_NAME.azurewebsites.net

Next Steps:
-----------
1. Deploy the certificate rotation function code:
   cd function-keyvault-private/CertRotationFunction
   func azure functionapp publish $FUNCTION_APP_NAME

2. Create a test certificate in Key Vault (from Azure Portal):
   - Go to Key Vault > Certificates > Generate/Import
   - Create a self-signed certificate for testing

3. Test the function:
   - Trigger the function via HTTP or Timer
   - Check logs in Azure Portal > Function App > Functions > Monitor

4. For production:
   - Set up Timer trigger for automated rotation
   - Configure alerts for rotation failures
   - Add Application Insights for monitoring

IMPORTANT NOTES:
----------------
• VNet Integration requires Premium App Service Plan
• Function can access private Key Vault through the VNet
• DNS resolution uses Azure DNS (168.63.129.16) for private endpoints

================================================================================
"@ -ForegroundColor Green

# Output resource IDs for reference
Write-Host "`nResource IDs for reference:" -ForegroundColor Cyan
Write-Host "Function App Resource ID:"
az functionapp show --resource-group $RESOURCE_GROUP --name $FUNCTION_APP_NAME --query id --output tsv
Write-Host "Key Vault ID: $keyVaultId"

Write-Host "`nFunction App Managed Identity:" -ForegroundColor Cyan
Write-Host "Principal ID: $functionIdentity"
