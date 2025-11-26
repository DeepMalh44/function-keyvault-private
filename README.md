# Azure Function + Private Key Vault Setup

This repository contains scripts to deploy an Azure Function App with VNet integration that can access a private endpoint-enabled Key Vault for certificate rotation.

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

## Key Configuration

- **VNet Integration**: Function App's outbound traffic routes through the VNet
- **Private Endpoint**: Key Vault is only accessible via private IP in the VNet
- **Private DNS Zone**: Resolves Key Vault hostname to private IP
- **Managed Identity**: Function authenticates to Key Vault without credentials
- **RBAC**: Function has `Key Vault Certificates Officer` and `Key Vault Secrets Officer` roles

## Files Structure

```
function-keyvault-private/
├── deploy-function-keyvault-private.ps1    # Deployment script
├── README.md                                # This file
└── CertRotationFunction/                    # Function App code
    ├── host.json                            # Function App configuration
    ├── requirements.psd1                    # PowerShell module dependencies
    ├── profile.ps1                          # Startup script
    ├── RotateCertificate/                   # HTTP-triggered function
    │   ├── function.json
    │   └── run.ps1
    └── AutoRotateCertificates/              # Timer-triggered function (daily)
        ├── function.json
        └── run.ps1
```

## Functions

### RotateCertificate (HTTP Trigger)

Manual certificate operations via HTTP requests.

**Actions:**
- `list` - List all certificates in Key Vault
- `check` - Check expiration status of all certificates
- `rotate` - Rotate a specific certificate
- `create` - Create a new self-signed certificate

**Example Requests:**
```bash
# List all certificates
curl "https://<function-app>.azurewebsites.net/api/RotateCertificate?action=list&code=<function-key>"

# Check expiration status
curl "https://<function-app>.azurewebsites.net/api/RotateCertificate?action=check&daysBeforeExpiry=30&code=<function-key>"

# Rotate a certificate
curl -X POST "https://<function-app>.azurewebsites.net/api/RotateCertificate?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"action": "rotate", "certificateName": "my-cert"}'

# Create a new certificate
curl -X POST "https://<function-app>.azurewebsites.net/api/RotateCertificate?code=<function-key>" \
  -H "Content-Type: application/json" \
  -d '{"action": "create", "certificateName": "new-cert"}'
```

### AutoRotateCertificates (Timer Trigger)

Automated daily certificate rotation check.

- **Schedule**: Daily at midnight (`0 0 0 * * *`)
- **Behavior**: Automatically rotates certificates expiring within 30 days
- **Logging**: Full audit trail in Function App logs

## Deployment

### Prerequisites

- Azure CLI installed and logged in
- Azure Functions Core Tools (for local development)
- PowerShell 7.x

### Deploy Infrastructure

```powershell
cd function-keyvault-private
.\deploy-function-keyvault-private.ps1
```

### Deploy Function Code

```bash
cd CertRotationFunction
func azure functionapp publish <function-app-name>
```

## Resources Created

| Resource | Description |
|----------|-------------|
| Resource Group | Container for all resources |
| Virtual Network | With 2 subnets (function integration + private endpoints) |
| Function App | PowerShell 7.4, Windows, Premium V2 plan |
| App Service Plan | P1V2 (required for VNet integration) |
| Storage Account | Required for Function App |
| Key Vault | RBAC authorization, private endpoint only |
| Private Endpoint | Connects Key Vault to VNet |
| Private DNS Zone | Resolves Key Vault to private IP |

## Important Notes

### VNet Integration Requirements

1. **Premium Plan Required**: VNet integration requires P1V2 or higher
2. **Subnet Delegation**: Function integration subnet must be delegated to `Microsoft.Web/serverFarms`
3. **Route All Traffic**: Set `WEBSITE_VNET_ROUTE_ALL=1` to route all outbound traffic through VNet
4. **DNS Configuration**: Set `WEBSITE_DNS_SERVER=168.63.129.16` for Azure DNS resolution

### Security Considerations

- ✅ Key Vault uses RBAC authorization (not access policies)
- ✅ Key Vault public access is disabled
- ✅ Function App uses Managed Identity (no stored credentials)
- ✅ RBAC follows least-privilege principle
- ✅ All traffic routed through VNet
- ⚠️ Consider adding Private Endpoint for Storage Account in production
- ⚠️ Enable Application Insights for monitoring

## Local Development

1. Install Azure Functions Core Tools:
   ```bash
   npm install -g azure-functions-core-tools@4
   ```

2. Login to Azure:
   ```bash
   az login
   ```

3. Run locally:
   ```bash
   cd CertRotationFunction
   func start
   ```

Note: Local development cannot access private Key Vault. Use a test Key Vault with public access for local testing.

## Cleanup

```bash
az group delete --name rg-function-keyvault-demo --yes --no-wait
```

## References

- [Azure Functions VNet Integration](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options#virtual-network-integration)
- [Key Vault Private Endpoints](https://learn.microsoft.com/en-us/azure/key-vault/general/private-link-service)
- [Managed Identities for Azure Functions](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity)
- [PowerShell Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell)
