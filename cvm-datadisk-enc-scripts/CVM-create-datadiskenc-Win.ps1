﻿#
# This script can be used to create an Azure Windows confidential VM and turn data disk encryption (DDE) feature on.
# Usage: Open this script file in "Windows PowerShell ISE". Review and update each "Step". Afterwards, highlight the section and hit F8 to run.
#
# Requirements: 1-) The confidential VM is already created with confidential OS disk encrtyption on
#               2-) One or more data disks are attached and partitioned. The volumes are formatted as NTFS.
#               3-) A Customer Managed Key (RSA 3072 bits) is created in AKV or mHSM with the modified SKR policy.
#               4-) A user assigned managed identity (UAI) is created and granted Get,Release permissions on the RSA key.
#


#### Step 0: Make sure your Azure powershell modules are up-to-date.

if ((Get-Module Az.Compute).Version.Major -lt 6)
{
    Update-Module -Name Az* -Force   # Requires elevated (admin) Powershell window
}

#### End of step 0



#### Step 1 - Set the global parameters which will be used throughout the script.

$subscriptionId    = "__SUB_ID_HERE__"                                      # User must have at least contributor access.
$user              = $env:USERNAME
$suffix            = [System.Guid]::NewGuid().ToString().Substring(0,8)     # Suffix to append to resources.
$resourceGroup     = "$user-win-dde-$suffix"                                # The RG will be created
$location          = "West US"                                              # "West US", "East US", "North Europe", "West Europe". See: 
$kvName            = "$user-akv-$suffix"                                    # AKV will be created.
$rsaKeyName        = "$user-dde-key1"                                       # RSA key will be created
$skrPolicyFile     = "C:\Temp\cvm\public_SKR_policy-datadisk.json"          # The SKR policy is slightly modified version for DDE. Copy it to your local and update path.
$uaManagedIdentity = "$user-ade-uai"                                        # User assigned identity will be created.

# CVM settings
$cvmName           = "$user-cvm-w22"                                        # CVM will be created.
$domainNameLabel   = "d1" + $resourceGroup
$vnetname          = "myVnet"
$vnetAddress       = "10.0.0.0/16"
$subnetname        = "slb" + $resourceGroup
$subnetAddress     = "10.0.2.0/24"
$OSDiskName        = $cvmName + "-osdisk"
$NICName           = $cvmName+ "-nic"
$NSGName           = $cvmName + "-NSG"
$PublicIPName      = $cvmName+ "-ip2"
$OSDiskSizeinGB    = 32
$VMSize            = "Standard_DC2ads_v5"
$PublisherName     = "MicrosoftWindowsServer"
$Offer             = "WindowsServer"
$SKU               = "2022-datacenter-smalldisk-g2"                         # You can choose Win Srv {2019, 2022} or Win Client 11.
$securityType      = "ConfidentialVM"
$secureboot        = $true
$vtpm              = $true

# Windows logon credentials.
$StrongPass = [System.Guid]::NewGuid()
Write-Host "Passwd in plain text (copy to notepad): $StrongPass"
$StrongPassSec = $StrongPass | ConvertTo-SecureString -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($user, $StrongPassSec)

#### End of step 1



#### Step 2 - Login to Azure and create a resource group

Login-AzAccount -Subscription $subscriptionId
New-AzResourceGroup -Name $resourceGroup -Location $location

#### End of step 2



#### Step 3 - Create a premium Azure Key Vault (or managed HSM, see online docs)

New-AzKeyVault -VaultName $kvName -ResourceGroupName $resourceGroup -Location $location -Sku Premium -EnablePurgeProtection
$keyvault = Get-AzKeyVault -VaultName $kvName -ResourceGroupName $resourceGroup
Add-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyName -Destination HSM -KeyType RSA -Size 3072 -KeyOps wrapKey,unwrapKey -Exportable -ReleasePolicyPath $skrPolicyFile
$rsaKey = Get-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyName

#### End of step 3



#### Step 4 - Create user assigned managed identity.

New-AzUserAssignedIdentity -Name $uaManagedIdentity -ResourceGroupName $resourceGroup -Location $location
$userAssignedMI = Get-AzUserAssignedIdentity -Name $uaManagedIdentity -ResourceGroupName $resourceGroup

# Wait for a few seconds for the MI to be available. If NotFound is returned, re-run the command.
Sleep 30
# Assign Get,Release permissions on the CMK to the User assigned MI.
Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $resourceGroup -ObjectId $userAssignedMI.PrincipalId -PermissionsToKeys get,release

#### End of step 4



#### Step 5 - Create a CVM and assign the Managed identity: This step takes ~5 mins, good time for a coffee break :-)

# Network resources
$frontendSubnet = New-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $subnetAddress
$vnet = New-AzVirtualNetwork -Name $vnetname -ResourceGroupName $resourceGroup -Location $location -AddressPrefix $vnetAddress -Subnet $frontendSubnet -Force
$publicIP = New-AzPublicIpAddress -Name $PublicIPName -ResourceGroupName $resourceGroup -AllocationMethod Static -DomainNameLabel $cvmName -Location $location -Sku Standard -Tier Regional -Force
$nic = New-AzNetworkInterface -Name $NICName -ResourceGroupName $resourceGroup -Location $location -SubnetId $vnet.Subnets[0].Id -EnableAcceleratedNetworking -Force -PublicIpAddressId $publicIP.Id

# VM creation
$vmConfig = New-AzVMConfig -VMName $cvmName -VMSize $VMSize
Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $cvmName -Credential $cred

Set-AzVMSourceImage -VM $vmConfig -PublisherName $PublisherName -Offer $Offer -Skus $SKU -Version latest
Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
$vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $securityType
$vmConfig = Set-AzVMUefi -VM $vmConfig -EnableVtpm $vtpm -EnableSecureBoot $secureboot

# SSE with PMK and CVM with CMK. Create a DES for OS Disk
$rsaKeyNameForOS = "$user-os-key1"
$desName = "$user-os-des1"
Add-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyNameForOS -Destination HSM -KeyType RSA -Size 3072 -KeyOps wrapKey,unwrapKey -Exportable -UseDefaultCVMPolicy
$rsaKeyForOS = Get-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyNameForOS
$desConfig = New-AzDiskEncryptionSetConfig -Location $location -KeyUrl $rsaKeyForOS.id -SourceVaultId $keyvault.ResourceId -IdentityType SystemAssigned -EncryptionType ConfidentialVmEncryptedWithCustomerKey 
$desConfig | New-AzDiskEncryptionSet -Name $desName -ResourceGroupName $resourceGroup
$des = Get-AzDiskEncryptionSet -Name $desName -ResourceGroupName $resourceGroup

# Wait for a few seconds for the MI to be available. If NotFound is returned, re-run the command.
Sleep 30
# Assign wrapKey,UnwrapKey for Confidential OS disk encryption.
Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $resourceGroup -ObjectId $des.Identity.PrincipalId -PermissionsToKeys get,wrapKey,unwrapKey

# Grant get, release permissions to Confidential Guest VM Agent.
$cvmAgent = Get-AzADServicePrincipal -DisplayName "Confidential Guest VM Agent"
Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $resourceGroup -ObjectId $cvmAgent.Id -PermissionsToKeys Get,Release

# Create the confidential VM.
$vmConfig = Set-AzVMOSDisk -VM $vmConfig -CreateOption FromImage -SecurityEncryptionType DiskWithVMGuestState -SecureVMDiskEncryptionSet $des.Id
New-AzVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig

# Add an empty datadisk of size 128GB
$vm = Get-AzVM -Name $cvmName -ResourceGroupName $resourceGroup
$dataDiskName = $cvmName+"-datadisk1"
$vm = Add-AzVMDataDisk -VM $vm -Name $dataDiskName -CreateOption Empty -Lun 2 -DiskSizeInGB 128 -Caching ReadOnly -DeleteOption Delete
Update-AzVM -VM $vm -ResourceGroupName $resourceGroup

# Assign the Managed Identity to the CVM
$vm = Get-AzVM -Name $cvmName -ResourceGroupName $resourceGroup
Update-AzVM -VM $vm -ResourceGroupName $resourceGroup -IdentityType UserAssigned -IdentityId $userAssignedMI.Id


# RDP to the VM and partition the data disk, run below commands in cmd. These commands are to be executed manually. (or in a CustomScriptExtension)
$ipAddress = $publicIP.IpAddress
Write-Host "mstsc $user@$ipAddress"
Write-Host "User: .\$user"
Write-Host "Passwd: $StrongPass"
Write-Host "Enter password above"
Write-Host "Open Cmd elevated"
Write-Host "diskmgmt.msc"
Write-Host "Initialize the data disk"
Write-Host "Create a volume of 20GB, format and assign drive letter."
Write-Host "Observe the volume is mounted on drive X and not encrypted. Neither the resource (temp) drive."

#### End of step 5.



#### Step 6 - Install ADE with public settings defined below to enable temp and data disk encryption.

# ADE settings:
$KV_URL                      = $keyvault.VaultUri
$KV_RID                      = $keyvault.ResourceId
$KEK_URL                     = $rsaKey.Id
$EncryptionManagedIdentity   = "EncryptionManagedIdentity";
$KV_UAI_RID                  = $userAssignedMI.Id

$Publisher                   = "Microsoft.Azure.Security"
$ExtName                     = "AzureDiskEncryption"
$ExtHandlerVer               = "2.4"
$EncryptionOperation         = "EnableEncryption"
$PrivatePreviewFlag_TempDisk = "PrivatePreview.ConfidentialEncryptionTempDisk"
$PrivatePreviewFlag_DataDisk = "PrivatePreview.ConfidentialEncryptionDataDisk"

# Settings for Azure Key Vault (AKV)
$pubSettings = @{};
$pubSettings.Add("KeyVaultURL", $KV_URL)
$pubSettings.Add("KeyVaultResourceId", $KV_RID)
$pubSettings.Add("KeyEncryptionKeyURL", $KEK_URL)
$pubSettings.Add("KekVaultResourceId", $KV_RID)
$pubSettings.Add("KeyEncryptionAlgorithm", "RSA-OAEP")
$pubSettings.Add("EncryptionManagedIdentity", $KV_UAI_RID)
$pubSettings.Add("VolumeType", "Data")
$pubSettings.Add($PrivatePreviewFlag_TempDisk, "true")
$pubSettings.Add($PrivatePreviewFlag_DataDisk, "true")
$pubSettings.Add("EncryptionOperation", $EncryptionOperation)

# Settings for Azure managed HSM (mHSM). For more info, see https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/overview
# $pubSettings = @{};
# $pubSettings.Add("KeyEncryptionKeyURL", $MHSM_KEK_URL)
# $pubSettings.Add("KekVaultResourceId", $MHSM_RID)
# $pubSettings.Add($EncryptionManagedIdentity, $KV_UAI_RID)
# $pubSettings.Add("VolumeType", "Data")
# $pubSettings.Add("KeyStoreType", "ManagedHSM")
# $pubSettings.Add("EncryptionOperation", $EncryptionOperation)

Set-AzVMExtension `
-ResourceGroupName $resourceGroup `
-VMName $cvmName `
-Publisher $Publisher `
-ExtensionType $ExtName `
-TypeHandlerVersion $ExtHandlerVer `
-Name $ExtName `
-EnableAutomaticUpgrade $false `
-Settings $pubSettings `
-Location $location

# Verify that the extension provision has succeded.
Get-AzVMExtension -ResourceGroupName $resourceGroup -VMName $cvmName -Name $ExtName -Status

# Verify in diskmgmt.msc that existing temp and data volumes got encrypted.
# Create additional volumes and and observe they get encrypted.


#### End of step 6.



#### Step 7 - Cleanup. Remove the extension or the resource group forall resources.

# Remove to repeat the install.
# Remove-AzVMExtension -ResourceGroupName $resourceGroup -VMName $cvmName -Name $ExtName


Remove-AzResourceGroup $resourceGroup

#### End of step 7.