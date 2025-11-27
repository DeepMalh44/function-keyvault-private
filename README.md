# Azure Function + Private Key Vault - Certificate Rotation

This repository contains a complete solution to deploy an Azure Function App with VNet integration that can access a private endpoint-enabled Key Vault for certificate management and rotation.

## ✅ Supported Scenario

Unlike Azure Automation cloud jobs, **Azure Functions with VNet Integration CAN access private endpoint-enabled resources**. This is the recommended approach for accessing private Key Vaults.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          Virtual Network                            │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐ │
│  │  Function Integration   │    │  Private Endpoint Subnet        │ │
│  │  Subnet (/24)           │    │  (/24)                          │ │
│  │  ┌───────────────────┐  │    │  ┌───────────────────────────┐  │ │
│  │  │  Delegated to     │──│────│──│  Private Endpoint         │  │ │
│  │  │  Function App     │  │    │  │  (Key Vault)              │  │ │
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
```

## Key Features

- **VNet Integration**: Function App's outbound traffic routes through the VNet
- **Private Endpoint**: Key Vault is only accessible via private IP in the VNet
- **Private DNS Zone**: Resolves Key Vault hostname to private IP
- **Managed Identity**: Function authenticates to Key Vault AND Storage without credentials
- **Identity-Based Storage**: No connection strings - uses `AzureWebJobsStorage__accountName` + `AzureWebJobsStorage__credential=managedidentity`
- **RBAC Authorization**: Function has proper roles on both Key Vault and Storage Account

## Quick Start

### Prerequisites

- Azure CLI installed and logged in (`az login`)
- Azure Functions Core Tools v4 (`npm install -g azure-functions-core-tools@4`)
- PowerShell 7.x

### One-Command Deployment

Deploy everything (infrastructure + function code) with a single command:

```powershell
cd function-keyvault-private
.\deploy-function-keyvault-private.ps1
```

The script will:
1. Create all Azure infrastructure
2. Configure managed identity with proper RBAC roles
3. Deploy the function code
4. Wait for initialization
5. Output the function key and test commands

### Infrastructure Only

If you only want to deploy infrastructure:

```powershell
.\deploy-function-keyvault-private.ps1 -SkipCodeDeployment
```

Then deploy code manually:

```bash
cd CertRotationFunction
func azure functionapp publish func-kv-rotation-777 --powershell
```

## Testing the Function

### Get Function Key

```powershell
# Get the function key
$funcKey = az functionapp function keys list `
    --resource-group rg-function-keyvault-demo-777 `
    --name func-kv-rotation-777 `
    --function-name RotateCertificate `
    --query default -o tsv

Write-Host "Function Key: $funcKey"
```

### Test Examples (PowerShell)

```powershell
# Set your function key
$funcKey = "YOUR_FUNCTION_KEY_HERE"
$baseUrl = "https://func-kv-rotation-777.azurewebsites.net/api/RotateCertificate"

# 1. List all certificates
Invoke-RestMethod -Uri "$baseUrl`?code=$funcKey&action=list"

# 2. Create a new certificate
Invoke-RestMethod -Uri "$baseUrl`?code=$funcKey&action=create&certificateName=my-test-cert" -Method Post

# 3. Check certificate expiration status (default: 30 days)
Invoke-RestMethod -Uri "$baseUrl`?code=$funcKey&action=check"

# 4. Check with custom expiration threshold (e.g., 60 days)
Invoke-RestMethod -Uri "$baseUrl`?code=$funcKey&action=check&daysBeforeExpiry=60"

# 5. Rotate a specific certificate
Invoke-RestMethod -Uri "$baseUrl`?code=$funcKey&action=rotate&certificateName=my-test-cert" -Method Post
```

### Test Examples (curl / Bash)

```bash
# Set your function key
FUNC_KEY="YOUR_FUNCTION_KEY_HERE"
BASE_URL="https://func-kv-rotation-777.azurewebsites.net/api/RotateCertificate"

# 1. List all certificates
curl "$BASE_URL?code=$FUNC_KEY&action=list"

# 2. Create a new certificate
curl -X POST "$BASE_URL?code=$FUNC_KEY&action=create&certificateName=my-test-cert"

# 3. Check certificate expiration status
curl "$BASE_URL?code=$FUNC_KEY&action=check"

# 4. Check with custom expiration threshold
curl "$BASE_URL?code=$FUNC_KEY&action=check&daysBeforeExpiry=60"

# 5. Rotate a specific certificate
curl -X POST "$BASE_URL?code=$FUNC_KEY&action=rotate&certificateName=my-test-cert"
```

### Expected Responses

**List Certificates:**
```json
{
  "action": "list",
  "keyVault": "kv-func-777",
  "certificates": [
    {
      "Name": "my-test-cert",
      "Expires": "2026-11-26",
      "DaysUntilExpiry": 364,
      "Status": "OK",
      "NeedsRotation": false
    }
  ],
  "count": 1,
  "success": true,
  "message": "Found 1 certificate(s)",
  "timestamp": "2025-11-26 23:45:00"
}
```

**Create Certificate:**
```json
{
  "action": "create",
  "keyVault": "kv-func-777",
  "certificate": {
    "name": "my-test-cert",
    "expires": "2026-11-26",
    "subject": "CN=my-test-cert",
    "thumbprint": "ABC123..."
  },
  "success": true,
  "message": "Certificate 'my-test-cert' created successfully",
  "timestamp": "2025-11-26 23:45:00"
}
```

**Check Expiration:**
```json
{
  "action": "check",
  "keyVault": "kv-func-777",
  "daysBeforeExpiry": 30,
  "certificates": [...],
  "expiringCount": 0,
  "totalCount": 1,
  "success": true,
  "message": "Found 0 certificate(s) expiring within 30 days",
  "timestamp": "2025-11-26 23:45:00"
}
```

## Files Structure

```
function-keyvault-private/
├── deploy-function-keyvault-private.ps1    # Complete deployment script
├── README.md                                # This file
└── CertRotationFunction/                    # Function App code
    ├── host.json                            # Function App configuration
    ├── requirements.psd1                    # PowerShell module dependencies
    ├── profile.ps1                          # Startup script (managed identity)
    ├── local.settings.json                  # Local development settings
    ├── RotateCertificate/                   # HTTP-triggered function
    │   ├── function.json
    │   └── run.ps1
    └── AutoRotateCertificates/              # Timer-triggered function (daily)
        ├── function.json
        └── run.ps1
```

## Function Endpoints

### RotateCertificate (HTTP Trigger)

Manual certificate operations via HTTP requests.

| Action | Method | Parameters | Description |
|--------|--------|------------|-------------|
| `list` | GET | - | List all certificates in Key Vault |
| `check` | GET | `daysBeforeExpiry` (optional, default: 30) | Check expiration status |
| `create` | POST | `certificateName` (required) | Create new self-signed certificate |
| `rotate` | POST | `certificateName` (required) | Rotate (renew) existing certificate |

### AutoRotateCertificates (Timer Trigger)

Automated daily certificate rotation check.

- **Schedule**: Daily at midnight UTC (`0 0 0 * * *`)
- **Behavior**: Automatically rotates certificates expiring within 30 days
- **Logging**: Full audit trail in Function App logs

## App Settings Reference

The deployment script configures these critical app settings:

| Setting | Value | Description |
|---------|-------|-------------|
| `AzureWebJobsStorage__accountName` | `stfunckv777` | Storage account name for identity-based access |
| `AzureWebJobsStorage__credential` | `managedidentity` | Use managed identity for storage |
| `KEY_VAULT_NAME` | `kv-func-777` | Key Vault name for certificate operations |
| `WEBSITE_VNET_ROUTE_ALL` | `1` | Route all outbound traffic through VNet |
| `WEBSITE_DNS_SERVER` | `168.63.129.16` | Azure DNS for private endpoint resolution |

**Important**: The `AzureWebJobsStorage` connection string is **removed** to ensure managed identity is used.

## RBAC Roles

The Function App's managed identity is assigned these roles:

### On Storage Account
| Role | Purpose |
|------|---------|
| Storage Blob Data Contributor | Function app content and managed dependencies |
| Storage Queue Data Contributor | Function triggers and message processing |
| Storage Table Data Contributor | Function state and checkpoint data |

### On Key Vault
| Role | Purpose |
|------|---------|
| Key Vault Secrets Officer | Read/write secrets |
| Key Vault Certificates Officer | Create, read, rotate certificates |

## Resources Created

| Resource | Name | Description |
|----------|------|-------------|
| Resource Group | `rg-function-keyvault-demo-777` | Container for all resources |
| Virtual Network | `vnet-function-demo-777` | With 2 subnets |
| Function App | `func-kv-rotation-777` | PowerShell 7.4, Windows |
| App Service Plan | `asp-function-kv-777` | P1V2 (required for VNet) |
| Storage Account | `stfunckv777` | Function App storage |
| Key Vault | `kv-func-777` | RBAC auth, private only |
| Private Endpoint | `pe-keyvault-777` | Key Vault private access |
| Private DNS Zone | `privatelink.vaultcore.azure.net` | DNS resolution |

## Troubleshooting

### Function Key Returns Error

If getting the function key fails with "Bad Request":

1. **Wait longer**: Managed dependencies (Az.KeyVault, Az.Accounts) take 2-5 minutes to download on first start
2. **Check app status**:
   ```powershell
   az functionapp show --resource-group rg-function-keyvault-demo-777 --name func-kv-rotation-777 --query "{state:state, availabilityState:availabilityState}"
   ```
3. **Restart the function app**:
   ```powershell
   az webapp restart --resource-group rg-function-keyvault-demo-777 --name func-kv-rotation-777
   ```

### Function Can't Access Key Vault

1. **Verify VNet Integration**:
   ```powershell
   az functionapp vnet-integration list --resource-group rg-function-keyvault-demo-777 --name func-kv-rotation-777
   ```

2. **Check RBAC roles**:
   ```powershell
   $principalId = az functionapp identity show --resource-group rg-function-keyvault-demo-777 --name func-kv-rotation-777 --query principalId -o tsv
   az role assignment list --assignee $principalId --output table
   ```

3. **Verify DNS resolution** (from function logs):
   - Key Vault should resolve to private IP (10.0.2.x)

### Storage Access Issues

Ensure these settings exist:
```powershell
az functionapp config appsettings list --resource-group rg-function-keyvault-demo-777 --name func-kv-rotation-777 --query "[?contains(name, 'AzureWebJobsStorage')]"
```

Should show:
- `AzureWebJobsStorage__accountName` = `stfunckv777`
- `AzureWebJobsStorage__credential` = `managedidentity`

And should NOT show `AzureWebJobsStorage` (connection string).

## Local Development

1. Install Azure Functions Core Tools:
   ```bash
   npm install -g azure-functions-core-tools@4
   ```

2. Login to Azure:
   ```bash
   az login
   ```

3. Create `local.settings.json` (for testing with public Key Vault):
   ```json
   {
     "IsEncrypted": false,
     "Values": {
       "FUNCTIONS_WORKER_RUNTIME": "powershell",
       "AzureWebJobsStorage": "UseDevelopmentStorage=true",
       "KEY_VAULT_NAME": "your-test-keyvault"
     }
   }
   ```

4. Run locally:
   ```bash
   cd CertRotationFunction
   func start
   ```

**Note**: Local development cannot access private Key Vault. Use a test Key Vault with public access for local testing.

## Cleanup

```powershell
# Delete the resource group and all resources
az group delete --name rg-function-keyvault-demo-777 --yes --no-wait

# Verify deletion
az group show --name rg-function-keyvault-demo-777
```

## Security Considerations

- ✅ Key Vault uses RBAC authorization (not access policies)
- ✅ Key Vault public access is disabled
- ✅ Function App uses Managed Identity (no stored credentials)
- ✅ Storage uses identity-based access (no connection strings)
- ✅ RBAC follows least-privilege principle
- ✅ All traffic routed through VNet
- ⚠️ Consider adding Private Endpoint for Storage Account in production
- ⚠️ Enable Application Insights for monitoring

## References

- [Azure Functions VNet Integration](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options#virtual-network-integration)
- [Key Vault Private Endpoints](https://learn.microsoft.com/en-us/azure/key-vault/general/private-link-service)
- [Managed Identities for Azure Functions](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [Identity-Based Storage Connections](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity)
- [Azure Functions App Settings Reference](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings)
- [PowerShell Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
