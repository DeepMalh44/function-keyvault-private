using namespace System.Net

<#
.SYNOPSIS
    Azure Function to rotate certificates in Key Vault.

.DESCRIPTION
    This function demonstrates accessing a private endpoint-enabled Key Vault
    from an Azure Function with VNet integration. It can:
    - List certificates in Key Vault
    - Check certificate expiration dates
    - Rotate (renew) certificates that are expiring soon
    - Create new self-signed certificates

.PARAMETER Request
    The HTTP request object containing optional parameters:
    - action: "list", "check", "rotate", or "create"
    - certificateName: Name of the certificate (required for rotate/create)
    - daysBeforeExpiry: Number of days before expiry to trigger rotation (default: 30)

.NOTES
    Requires:
    - VNet Integration enabled on the Function App
    - Managed Identity with Key Vault Certificates Officer role
    - Key Vault with private endpoint in the same VNet
#>

param($Request, $TriggerMetadata)

# ============================================================================
# CONFIGURATION
# ============================================================================
$KeyVaultName = $env:KEY_VAULT_NAME
$DefaultDaysBeforeExpiry = 30

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

function Get-CertificateExpiryStatus {
    param(
        [Parameter(Mandatory)]
        $Certificate,
        [int]$DaysBeforeExpiry = 30
    )
    
    $expiryDate = $Certificate.Expires
    $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
    
    return @{
        Name = $Certificate.Name
        Expires = $expiryDate.ToString("yyyy-MM-dd")
        DaysUntilExpiry = $daysUntilExpiry
        NeedsRotation = $daysUntilExpiry -le $DaysBeforeExpiry
        Status = if ($daysUntilExpiry -le 0) { "EXPIRED" } 
                 elseif ($daysUntilExpiry -le $DaysBeforeExpiry) { "EXPIRING_SOON" }
                 else { "OK" }
    }
}

# ============================================================================
# MAIN LOGIC
# ============================================================================
Write-Log "Certificate Rotation Function triggered"
Write-Log "Key Vault: $KeyVaultName"

# Validate Key Vault name
if ([string]::IsNullOrEmpty($KeyVaultName)) {
    $body = @{
        success = $false
        error = "KEY_VAULT_NAME environment variable is not set"
    } | ConvertTo-Json
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $body
        ContentType = "application/json"
    })
    return
}

# Parse request parameters
$action = $Request.Query.action
if (-not $action) {
    $action = $Request.Body.action
}
if (-not $action) {
    $action = "list"  # Default action
}

$certificateName = $Request.Query.certificateName
if (-not $certificateName) {
    $certificateName = $Request.Body.certificateName
}

$daysBeforeExpiry = $Request.Query.daysBeforeExpiry
if (-not $daysBeforeExpiry) {
    $daysBeforeExpiry = $Request.Body.daysBeforeExpiry
}
if (-not $daysBeforeExpiry) {
    $daysBeforeExpiry = $DefaultDaysBeforeExpiry
}

Write-Log "Action: $action"
Write-Log "Certificate Name: $certificateName"
Write-Log "Days Before Expiry Threshold: $daysBeforeExpiry"

try {
    # Ensure we're connected to Azure
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Connecting to Azure using Managed Identity..." "INFO"
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Log "Successfully connected to Azure" "INFO"
    }

    $result = @{
        success = $true
        action = $action
        keyVault = $KeyVaultName
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }

    switch ($action.ToLower()) {
        # ================================================================
        # LIST: List all certificates in Key Vault
        # ================================================================
        "list" {
            Write-Log "Listing certificates in Key Vault: $KeyVaultName"
            
            $certificates = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -ErrorAction Stop
            
            $certList = @()
            foreach ($cert in $certificates) {
                $certDetails = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $cert.Name
                $certList += Get-CertificateExpiryStatus -Certificate $certDetails -DaysBeforeExpiry $daysBeforeExpiry
            }
            
            $result.certificates = $certList
            $result.count = $certList.Count
            $result.message = "Found $($certList.Count) certificate(s)"
            
            Write-Log "Found $($certList.Count) certificates"
        }
        
        # ================================================================
        # CHECK: Check certificates for expiration
        # ================================================================
        "check" {
            Write-Log "Checking certificate expiration status"
            
            $certificates = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -ErrorAction Stop
            
            $expiring = @()
            $expired = @()
            $ok = @()
            
            foreach ($cert in $certificates) {
                $certDetails = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $cert.Name
                $status = Get-CertificateExpiryStatus -Certificate $certDetails -DaysBeforeExpiry $daysBeforeExpiry
                
                switch ($status.Status) {
                    "EXPIRED" { $expired += $status }
                    "EXPIRING_SOON" { $expiring += $status }
                    "OK" { $ok += $status }
                }
            }
            
            $result.expired = $expired
            $result.expiringSoon = $expiring
            $result.ok = $ok
            $result.summary = @{
                total = $certificates.Count
                expired = $expired.Count
                expiringSoon = $expiring.Count
                ok = $ok.Count
            }
            $result.message = "Expired: $($expired.Count), Expiring Soon: $($expiring.Count), OK: $($ok.Count)"
            
            Write-Log $result.message
        }
        
        # ================================================================
        # ROTATE: Rotate a specific certificate
        # ================================================================
        "rotate" {
            if ([string]::IsNullOrEmpty($certificateName)) {
                throw "certificateName parameter is required for rotate action"
            }
            
            Write-Log "Rotating certificate: $certificateName"
            
            # Get current certificate
            $currentCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certificateName -ErrorAction Stop
            
            if (-not $currentCert) {
                throw "Certificate '$certificateName' not found in Key Vault"
            }
            
            # Get the certificate policy to use for renewal
            $policy = Get-AzKeyVaultCertificatePolicy -VaultName $KeyVaultName -Name $certificateName
            
            # Trigger renewal by creating a new version
            Write-Log "Creating new version of certificate: $certificateName"
            $operation = Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certificateName -CertificatePolicy $policy
            
            # Wait for the operation to complete
            $maxWait = 60
            $waited = 0
            while ($operation.Status -eq "inProgress" -and $waited -lt $maxWait) {
                Start-Sleep -Seconds 2
                $waited += 2
                $operation = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $certificateName
            }
            
            if ($operation.Status -eq "completed") {
                $newCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certificateName
                $result.certificate = @{
                    name = $certificateName
                    newThumbprint = $newCert.Thumbprint
                    newExpiry = $newCert.Expires.ToString("yyyy-MM-dd")
                    previousThumbprint = $currentCert.Thumbprint
                }
                $result.message = "Certificate '$certificateName' rotated successfully"
                Write-Log $result.message
            }
            else {
                throw "Certificate rotation did not complete. Status: $($operation.Status), Error: $($operation.ErrorMessage)"
            }
        }
        
        # ================================================================
        # CREATE: Create a new self-signed certificate
        # ================================================================
        "create" {
            if ([string]::IsNullOrEmpty($certificateName)) {
                throw "certificateName parameter is required for create action"
            }
            
            Write-Log "Creating new self-signed certificate: $certificateName"
            
            # Create certificate policy for self-signed cert
            $policy = New-AzKeyVaultCertificatePolicy `
                -SubjectName "CN=$certificateName" `
                -IssuerName "Self" `
                -ValidityInMonths 12 `
                -KeyType RSA `
                -KeySize 2048 `
                -Ekus "1.3.6.1.5.5.7.3.1", "1.3.6.1.5.5.7.3.2" `
                -KeyUsage DigitalSignature, KeyEncipherment
            
            # Create the certificate
            $operation = Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certificateName -CertificatePolicy $policy
            
            # Wait for completion
            $maxWait = 60
            $waited = 0
            while ($operation.Status -eq "inProgress" -and $waited -lt $maxWait) {
                Start-Sleep -Seconds 2
                $waited += 2
                $operation = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $certificateName
            }
            
            if ($operation.Status -eq "completed") {
                $newCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certificateName
                $result.certificate = @{
                    name = $certificateName
                    thumbprint = $newCert.Thumbprint
                    expires = $newCert.Expires.ToString("yyyy-MM-dd")
                    subject = "CN=$certificateName"
                }
                $result.message = "Certificate '$certificateName' created successfully"
                Write-Log $result.message
            }
            else {
                throw "Certificate creation did not complete. Status: $($operation.Status), Error: $($operation.ErrorMessage)"
            }
        }
        
        default {
            throw "Invalid action: $action. Valid actions are: list, check, rotate, create"
        }
    }
    
    $body = $result | ConvertTo-Json -Depth 5
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $body
        ContentType = "application/json"
    })
}
catch {
    Write-Log "Error: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    
    $errorResult = @{
        success = $false
        error = $_.Exception.Message
        action = $action
        keyVault = $KeyVaultName
        timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json
    
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body = $errorResult
        ContentType = "application/json"
    })
}

Write-Log "Function execution completed"
