$ErrorActionPreference = "Stop"

# =========================
# GLOBAL CONFIG
# =========================
$subscriptionId = "<Your-Subscription-ID>"
$resourceGroup  = "<Your Resource Group>"
$vmName         = "<Your VM Name>"
$location       = "<VM Location>"
$SqlEdition     = "<Desired SQL edition>"

# SQL CONFIG
$SqlAuthMode   = "<Put Windows or Mixed>"
$SaPassword    = "<Put Password>"
$SqlCollation  = "<Put Required Collation>"
$InstallSSIS   = <Put $true or $false as per requirement>

# SERVICE PRINCIPAL
$clientId     = "<Your Client ID>"
$clientSecret = "<Your Client Secret>"
$tenantId     = "<Your Tenant ID>"

# =========================
# HELPERS
# =========================
function Run-Step {
    param($Name, $Script)
    Write-Host "`n===== $Name =====" -ForegroundColor Cyan
    try {
        & $Script
        Write-Host "SUCCESS: $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAILED: $Name" -ForegroundColor Red
        throw
    }
}

function Invoke-VMEncoded {
    param($scriptContent)
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($scriptContent)
    $encoded = [Convert]::ToBase64String($bytes)

    az vm run-command invoke `
        -g $resourceGroup `
        -n $vmName `
        --command-id RunPowerShellScript `
        --scripts "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

function Wait-AfterRestart {
    Write-Host "Waiting 180 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 180
}

# =========================
# STEP 0 - LOGIN
# =========================
Run-Step "Azure Login" {
    az login --service-principal -u $clientId -p $clientSecret --tenant $tenantId | Out-Null
    az account set --subscription $subscriptionId
}

# =========================
# STEP 1 - DISK SETUP
# =========================
Run-Step "Disk Setup" {

    $vmSize = az vm show -g $resourceGroup -n $vmName --query "hardwareProfile.vmSize" -o tsv

    switch ($vmSize) {
        "<Put Small VM Size>"  { $dataDisk=<put value in gb>; $logDisk=<put value in gb>;  $tempDisk=<put value in gb> }
        "<Put Medium VM size>"  { $dataDisk=<put value in gb>; $logDisk=<put value in gb>; $tempDisk=<put value in gb> }
        "<Put large VM size>"  { $dataDisk=<put value in gb>; $logDisk=<put value in gb>; $tempDisk=<put value in gb> }
        "<Put Extra Large VM size>" { $dataDisk=<put value in gb>;$logDisk=<put value in gb>; $tempDisk=<put value in gb> }
        default { throw "Unsupported VM size: $vmSize" }
    }

    az disk create -g $resourceGroup -n "$vmName-data" --size-gb $dataDisk --sku Premium_LRS --location $location
    az disk create -g $resourceGroup -n "$vmName-log"  --size-gb $logDisk  --sku Premium_LRS --location $location
    az disk create -g $resourceGroup -n "$vmName-temp" --size-gb $tempDisk --sku Premium_LRS --location $location

    az vm disk attach -g $resourceGroup --vm-name $vmName --name "$vmName-data" --lun 0 --caching ReadOnly
    az vm disk attach -g $resourceGroup --vm-name $vmName --name "$vmName-log"  --lun 1 --caching None
    az vm disk attach -g $resourceGroup --vm-name $vmName --name "$vmName-temp" --lun 2 --caching ReadOnly

$inner = @'
$ErrorActionPreference = "Stop"
Write-Output "--- STARTING DISK INITIALIZATION ---"

# Force Rescan
"rescan" | diskpart
Start-Sleep -Seconds 120

$mapping = @(
    @{LUN=0; Letter="S"; Label="SQLData"},
    @{LUN=1; Letter="L"; Label="SQLLogs"},
    @{LUN=2; Letter="Q"; Label="TempDB"}
)

foreach ($m in $mapping) {
    # Find the disk object by LUN
    $disk = Get-Disk | Where-Object { $_.Location -like "*LUN $($m.LUN)*" } | Select-Object -First 1
    
    if ($null -eq $disk) {
        Write-Output "LUN $($m.LUN) not found. Skipping."
        continue
    }

    Write-Output "Processing Disk $($disk.Number) for LUN $($m.LUN)"

    # Bring Online and Clear Attributes
    $disk | Set-Disk -IsOffline $false -ErrorAction SilentlyContinue
    $disk | Set-Disk -IsReadOnly $false -ErrorAction SilentlyContinue

    # Clean, Initialize, and Partition
    Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue

    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $m.Letter
    Start-Sleep -Seconds 5
    
    # 64KB formatting for SQL Server Best Practices
    $part | Format-Volume -FileSystem NTFS -NewFileSystemLabel $m.Label -AllocationUnitSize 65536 -Confirm:$false -Force
    
    Write-Output "Drive $($m.Letter): Success (64KB Cluster)"
}
Write-Output "--- COMPLETED ---"
'@

Invoke-VMEncoded $inner

Start-Sleep -Seconds 60
}

# =========================
# STEP 2 - SQL ISO DOWNLOAD
# =========================
Run-Step "SQL ISO Download" {

$storageAccount = "<put Storage account name>"
$container = "<Put Container name where ISO files are present>"
$blobName = if ($SqlEdition -eq "Standard") { "<Put ISO file name here with extension> " } 
            else { "<Put ISO file name here with extension>" }

Write-Host "--- STEP 2: Generating SAS Token ---" -ForegroundColor Cyan
$expiry = (Get-Date).AddHours(4).ToString("yyyy-MM-ddTHH:mm:ssZ")
$accountKey = az storage account keys list -g $resourceGroup -n $storageAccount --query "[0].value" -o tsv

$sasToken = az storage blob generate-sas `
    --account-name $storageAccount `
    --account-key $accountKey `
    --container-name $container `
    --name $blobName `
    --permissions r `
    --expiry $expiry `
    --full-uri -o tsv

Write-Host "SAS URI Generated Successfully." -ForegroundColor Green

# 🚀 3. INTERNAL VM SCRIPT (Using Single Quotes to prevent local expansion)
$innerScript = @'
    $ErrorActionPreference = "Stop"
    Write-Output "[VM] Starting Download Process..."
    
    $DownloadPath = "C:\Installers"
    if (-not (Test-Path $DownloadPath)) { New-Item $DownloadPath -ItemType Directory }
    
    $IsoPath = Join-Path $DownloadPath "@BLOBNAME@"
    $InstallerPath = Join-Path $DownloadPath "SQL_Setup"

    Write-Output "[VM] Downloading ISO..."
    Invoke-WebRequest -Uri '@SASURI@' -OutFile $IsoPath -UseBasicParsing
    
    Write-Output "[VM] Download Successful. Size: $((Get-Item $IsoPath).Length / 1GB) GB"

    Write-Output "[VM] Mounting ISO..."
    $Mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $DriveLetter = ($Mount | Get-Volume).DriveLetter
    Write-Output "[VM] ISO Mounted to Drive: $DriveLetter"

    if (Test-Path $InstallerPath) { Remove-Item $InstallerPath -Recurse -Force }
    New-Item $InstallerPath -ItemType Directory

    Write-Output "[VM] Extracting files..."
    Copy-Item -Path "$($DriveLetter):\*" -Destination $InstallerPath -Recurse -Force
    
    Dismount-DiskImage -ImagePath $IsoPath
    Write-Output "--- [VM] PREPARATION FINISHED ---"
'@

# Replace placeholders with the actual generated values before encoding
$innerScript = $innerScript.Replace("@BLOBNAME@", $blobName).Replace("@SASURI@", $sasToken)

Invoke-VMEncoded $innerScript

Start-Sleep -Seconds 60

}

# =========================
# STEP 3 - SQL INSTALL PHASE 1
# =========================
Run-Step "SQL Install Phase 1" {

#PHASE 1: PREPARE ENVIRONMENT (AD Group + dbatools + NuGet)
$phase1Script = @'
    $ErrorActionPreference = "Stop"
    Write-Output "[VM] Phase 1: Preparing Environment..."
    
    # Add AD Admin Group
    Add-LocalGroupMember -Group "Administrators" -Member "<Put windows Admin Account>" -ErrorAction SilentlyContinue
    
    # Install NuGet and dbatools
   [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -ForceBootstrap -Force -Confirm:$false
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module -Name dbatools -Force -AllowClobber -Scope AllUsers -Confirm:$false
    
    Write-Output "[VM] Phase 1 Complete. Ready for Restart."
'@

Write-Host "--- Starting Phase 1: Environment Setup ---" -ForegroundColor Cyan
Invoke-VMEncoded $phase1Script

# 🔄 3. RESTART VM
Write-Host "--- Restarting VM to clear all pending flags ---" -ForegroundColor Yellow
az vm restart -g $resourceGroup -n $vmName --no-wait
Write-Host "Waiting 3 minutes for the VM to fully initialize..." -ForegroundColor Yellow
Start-Sleep -Seconds 180
}

# =========================
# STEP 3 - SQL INSTALL PHASE 2
# =========================
Run-Step "SQL Install Phase 2" {

$SelectedFeatures = if ($InstallSSIS) { "Default,IntegrationServices" } else { "Default" }

$phase2Script = @"
    `$ErrorActionPreference = "Stop"
    Write-Output "[VM] Phase 2: Starting SQL Installation after Reboot..."

    `$InstallParams = @{
        Version            = <Put Intended SQL Vesrion>
        InstanceName       = "MSSQLSERVER"
        Path               = "C:\Installers\SQL_Setup"
        Feature            = "$SelectedFeatures".Split(',')
        AuthenticationMode = "$SqlAuthMode"
        InstancePath       = "S:\MSSQL"
        DataPath           = "S:\Data"
        LogPath            = "L:\Log"
        TempPath           = "Q:\TempDB"
        AdminAccount       = "<Put Windows Admin account>"
        SqlCollation       = "$SqlCollation"
        NoPendingRenameCheck = `$true
        Confirm            = `$false
        SaCredential       = New-Object System.Management.Automation.PSCredential ("sa", (ConvertTo-SecureString "xxxxxxxxxxxxxxxxx" -AsPlainText -Force))
    }

    Install-DbaInstance @InstallParams
"@

Write-Host "--- Starting Phase 2: SQL Server 2025 Installation ---" -ForegroundColor Cyan
Invoke-VMEncoded $phase2Script
}

# =========================
# STEP 4 - SSMS
# =========================
Run-Step "SSMS Install" {

$inner=@'
$ErrorActionPreference = "Stop"

    # 1. Ensure TLS 1.2 for download
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # 2. Setup Directory
    $installDir = "C:\Installers"
    if (!(Test-Path $installDir)) { New-Item -Path $installDir -ItemType Directory -Force }
    $installerPath = Join-Path $installDir "SSMS-Setup.exe"

    # 3. Download SSMS
    Write-Output "[VM] Downloading SSMS..."
    Invoke-WebRequest -Uri "https://aka.ms/ssmsfullsetup" -OutFile $installerPath -UseBasicParsing

    # 4. Silent Install
    Write-Output "[VM] Installing SSMS..."
    $process = Start-Process -FilePath $installerPath -ArgumentList "/install /quiet /norestart" -Wait -PassThru

    # 5. Check Result and Restart
    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Output "[VM] SSMS installed. Restarting..."
        Restart-Computer -Force
    } else {
        throw "SSMS Installation failed with Exit Code: $($process.ExitCode)"
    }
'@

Invoke-VMEncoded $inner
}

Wait-AfterRestart

# =========================
# STEP 5 - PATCH
# =========================
Run-Step "SQL Patch" {

$innerScript = @'
$ErrorActionPreference = "Stop"

Import-Module dbatools
Set-DbatoolsInsecureConnection -SessionOnly

# =========================
# CONFIG
# =========================
$downloadPath = "C:\Installers\sql_patch"
$logPath = "$downloadPath\patch_log.txt"

# =========================
# CREATE DIRECTORY
# =========================
if (!(Test-Path $downloadPath)) {
    New-Item -ItemType Directory -Path $downloadPath -Force | Out-Null
}

# =========================
# START LOGGING
# =========================
Start-Transcript -Path $logPath -Append

# =========================
# GET FQDN
# =========================
$fqdn = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
Write-Output "[VM] Using FQDN: $fqdn"

try {
    Write-Output "[VM] ===== STARTING SQL PATCH ====="

    Update-DbaInstance `
        -ComputerName $fqdn `
        -InstanceName "MSSQLSERVER" `
        -Download `
        -Path $downloadPath `
        -Confirm:$false `
        -Verbose

    Write-Output "[VM] Patch installation completed"

    # =========================
    # FORCE RESTART
    # =========================
    Write-Output "[VM] Restarting server (forced)..."
    Restart-Computer -Force

}
catch {
    Write-Output "[VM] ERROR OCCURRED:"
    Write-Output $_
    Stop-Transcript
    exit 1
}

Stop-Transcript
'@

Invoke-VMEncoded $innerScript
}


Write-Host "`n🎉 ALL STEPS COMPLETED SUCCESSFULLY 🎉" -ForegroundColor Green