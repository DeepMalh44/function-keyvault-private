<#
.SYNOPSIS
    Timer-triggered Azure Function for automated certificate rotation.

.DESCRIPTION
    This function runs daily (configurable) to check all certificates in Key Vault
    and automatically rotates any that are expiring within the threshold period.

    Schedule: Runs daily at midnight (0 0 0 * * *)
    
.NOTES
    Requires:
    - VNet Integration enabled on the Function App
    - Managed Identity with Key Vault Certificates Officer role
    - Key Vault with private endpoint in the same VNet
#>

param($Timer)

# ============================================================================
# CONFIGURATION
# ============================================================================
$KeyVaultName = $env:KEY_VAULT_NAME
$DaysBeforeExpiry = 30  # Rotate certificates expiring within 30 days

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

# ============================================================================
# MAIN LOGIC
# ============================================================================
Write-Log "=========================================="
Write-Log "Automated Certificate Rotation - Started"
Write-Log "=========================================="
Write-Log "Key Vault: $KeyVaultName"
Write-Log "Rotation Threshold: $DaysBeforeExpiry days"

# Check if the timer is past due
if ($Timer.IsPastDue) {
    Write-Log "Timer is past due! Running catch-up execution." "WARNING"
}

# Validate configuration
if ([string]::IsNullOrEmpty($KeyVaultName)) {
    Write-Log "ERROR: KEY_VAULT_NAME environment variable is not set" "ERROR"
    throw "KEY_VAULT_NAME environment variable is not set"
}

try {
    # Connect to Azure using Managed Identity
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Connecting to Azure using Managed Identity..."
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Log "Successfully connected to Azure"
    }
    
    # Get all certificates from Key Vault
    Write-Log "Retrieving certificates from Key Vault..."
    $certificates = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -ErrorAction Stop
    Write-Log "Found $($certificates.Count) certificate(s)"
    
    $rotated = @()
    $failed = @()
    $skipped = @()
    
    foreach ($cert in $certificates) {
        $certName = $cert.Name
        Write-Log "Checking certificate: $certName"
        
        try {
            # Get full certificate details
            $certDetails = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certName
            $expiryDate = $certDetails.Expires
            $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
            
            Write-Log "  Expires: $($expiryDate.ToString('yyyy-MM-dd')) ($daysUntilExpiry days)"
            
            if ($daysUntilExpiry -le $DaysBeforeExpiry) {
                Write-Log "  Certificate needs rotation!" "WARNING"
                
                # Get the certificate policy
                $policy = Get-AzKeyVaultCertificatePolicy -VaultName $KeyVaultName -Name $certName
                
                # Rotate the certificate
                Write-Log "  Initiating rotation..."
                $operation = Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certName -CertificatePolicy $policy
                
                # Wait for completion
                $maxWait = 120
                $waited = 0
                while ($operation.Status -eq "inProgress" -and $waited -lt $maxWait) {
                    Start-Sleep -Seconds 5
                    $waited += 5
                    $operation = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $certName
                }
                
                if ($operation.Status -eq "completed") {
                    $newCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $certName
                    Write-Log "  ✓ Rotated successfully. New expiry: $($newCert.Expires.ToString('yyyy-MM-dd'))" "INFO"
                    $rotated += @{
                        Name = $certName
                        OldExpiry = $expiryDate.ToString('yyyy-MM-dd')
                        NewExpiry = $newCert.Expires.ToString('yyyy-MM-dd')
                        OldThumbprint = $certDetails.Thumbprint
                        NewThumbprint = $newCert.Thumbprint
                    }
                }
                else {
                    throw "Operation status: $($operation.Status), Error: $($operation.ErrorMessage)"
                }
            }
            else {
                Write-Log "  ✓ Certificate is valid, no rotation needed"
                $skipped += @{
                    Name = $certName
                    Expires = $expiryDate.ToString('yyyy-MM-dd')
                    DaysUntilExpiry = $daysUntilExpiry
                }
            }
        }
        catch {
            Write-Log "  ✗ Failed to process certificate: $_" "ERROR"
            $failed += @{
                Name = $certName
                Error = $_.Exception.Message
            }
        }
    }
    
    # Summary
    Write-Log "=========================================="
    Write-Log "Rotation Summary"
    Write-Log "=========================================="
    Write-Log "Total Certificates: $($certificates.Count)"
    Write-Log "Rotated: $($rotated.Count)"
    Write-Log "Skipped (not expiring): $($skipped.Count)"
    Write-Log "Failed: $($failed.Count)"
    
    if ($rotated.Count -gt 0) {
        Write-Log "Rotated Certificates:"
        foreach ($r in $rotated) {
            Write-Log "  - $($r.Name): $($r.OldExpiry) -> $($r.NewExpiry)"
        }
    }
    
    if ($failed.Count -gt 0) {
        Write-Log "Failed Certificates:" "WARNING"
        foreach ($f in $failed) {
            Write-Log "  - $($f.Name): $($f.Error)" "ERROR"
        }
    }
    
    Write-Log "=========================================="
    Write-Log "Automated Certificate Rotation - Completed"
    Write-Log "=========================================="
}
catch {
    Write-Log "Fatal error during certificate rotation: $_" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
    throw
}
