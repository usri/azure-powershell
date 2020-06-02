<#
.SYNOPSIS
Restore an archive from blob.

.DESCRIPTION
This script will restore a compressed zip file from blob to a VM file system. If the blob is in the archive tier, it will rehydrate it first, before copying and restoring it.

.PARAMETER StorageAccountName
Name of the storage account to upload the archive file to. Cannot be used with ContainerURI.

.PARAMETER ContainerName
Name of the container to upload the archive file to. Cannot be used with BlobUri.

.PARAMETER BlobName
Name of the container to upload the archive file to. Cannot be used with BlobUri.

.PARAMETER BlobUri
URI of the compressed archive file. Using this parameter assumes that you can only access this file via SAS token. When using BlobUri, the file will NOT be rehydrated. For files in an achive tier, the storage account naming convention will need to be used. Cannot be used with -StorageAccountName, -ContainerName, -ManagedIdentity, or -Environment

.PARAMETER RehydrationPriority
Priority level for rehydration of any blob in Archive tier

.PARAMETER RehydrationToContainer
Container with in the Storage Account to copy the Archive blob to. This will create a copy of the blob contents without moving the original from Archive.

.PARAMETER DestinationPath
Path where the archive should be expanded into. This script will create a folder underneath the -DestinationPath, but it will NOT create it. This directory must exists before the script will start.

.PARAMETER KeepArchiveFile
Keeps the archive zip file in the -ArchiveTempDir location after restoring the files. If not specified the zip file will be deleted from the local machine once expanding has completed successfully.

.PARAMETER ArchiveTempDir
Directory to use for the .7z archive compression to reside. If no directory is specific, the archive will be placed in the TEMP directory specified by the current environment variable.

.PARAMETER ZipCommandDir
Specifies the directory where the 7z.exe command can be found. If not specified, it will look in the current PATH

.PARAMETER AzCopyCommandDir
Specifies the directory where the azcpoy.exe command can be found. If not specified, it will look in the current PATH

.PARAMETER UseManagedIdentity
Specifies the use of Managed Identity to authenticate into Azure Powershell APIs and azcopy.exe. If not specified, the AzureCloud is use by default. Cannot be used with

.PARAMETER Environment
Specifies the Azure cloud environment to use for authentication. If not specified the AzureCloud is used by default

.PARAMETER Force
Execute restore without confirmation

.EXAMPLE
RestoreArchive.ps1 -StorageAccountName 'myStorageAccount' -ContainerName 'archive-continer' -BlobName 'archive.7z' -DestinationPath c:\restored-archives
#>

[CmdletBinding()]
param (
    [Parameter(ParameterSetName = "StorageAccount", Mandatory)]
    [string] $StorageAccountName,

    [Parameter(ParameterSetName = "StorageAccount", Mandatory)]
    [string] $ContainerName,

    [Parameter(ParameterSetName = "StorageAccount")]
    [string] $BlobName,

    [Parameter(ParameterSetName = "BlobUri", Mandatory)]
    [string] $BlobUri,

    [string] $DestinationPath = '.\',

    [Parameter(ParameterSetName = "StorageAccount")]
    [ValidateSet('Standard','High')]
    [string] $RehydratePriority = 'Standard',

    [Parameter(ParameterSetName = "StorageAccount")]
    [string] $RehydrateToContainer,

    [switch] $KeepArchiveFile,

    [switch] $RestoreEmptyDirectories,

    [string] $LogOutputDir,

    [string] $ArchiveTempDir = $env:TEMP,

    [string] $ZipCommandDir = "",

    [string] $AzCopyCommandDir = "",

    [Parameter(ParameterSetName = "StorageAccount")]
    [switch] $UseManagedIdentity,

    [Parameter(ParameterSetName = "StorageAccount")]
    [string] $Environment,

    [switch] $Force

)

#####################################################################
function LogOutput
{
    [CmdletBinding()]
    param (
        [Parameter(Position=0)]
        [string] $blobName,

        [Parameter(Position=1)]
        [string] $message
    )

    $logFile = $blobName + '.log'

    if ($script:LogOutputDir) {
        "$(Get-Date) $message" | Out-File -Path "$($script:LogOutputDir)$($logFile)" -Append
    }
    Write-Host "$(Get-Date) $($blobName): $message"
}

#####################################################################
function RehydrateBlob {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Blob,

        [Parameter(Mandatory)]
        [string] $RehydratePriority
    )

    $elapsed = $null

    $blobName = $Blob.Name
    $containerName = $Blob.ICloudBlob.container.Name

    if (-not $Blob.ICloudBlob.Properties.RehydrationStatus) {
        $Blob.ICloudBlob.SetStandardBlobTier('Hot', $RehydratePriority)
        LogOutput -BlobName $Blob -Message "Rehydrate requested"
        $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    } else {
        LogOutput -BlobName $Blob -Message "Rehydrate already under way"
    }

    # rehydrate blob if necessary
    while ($Blob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive') {
        LogOutput -Blobname $blobName -Message "tier:$($Blob.ICloudBlob.Properties.StandardBlobTier)...rehydration:$($Blob.ICloudBlob.Properties.RehydrationStatus) (next update in 10 mins)... "
        Start-Sleep 600 # 10 mins

        $blob = Get-AzStorageBlob -Context $Blob.Context -Container $containerName -Blob $blobName
        if (-not $blob) {
            LogOutput -BlobName $blobName -Message "Unable to find $blobName in $containerName"
            throw "Unable to find $blobName in $containerName"
        }
    }

    if ($elapsed) {
        LogOutput -BlobName $blobName -Message "Rehydration complete. ($($elapsed.Elapsed.ToString()))"
    }

    return $blob
}

#####################################################################
function RehydrateBlobCopy {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Blob,

        [Parameter(Mandatory)]
        [string] $RehydratePriority,

        [Parameter()]
        [string] $RehydrateToContainer

    )

    $elapsed = $null

    #region - check to see if a copy exists
    $destBlob = Get-AzStorageBlob -Context $Blob.Context -Container $RehydrateToContainer -Blob $Blob.Name -ErrorAction SilentlyContinue
    if (-not $destBlob) {
        try {
            $destBlob = Start-AzStorageBlobCopy `
                -SrcContainer $Blob.ICloudBlob.Container.Name `
                -SrcBlob $Blob.Name `
                -DestContainer $RehydrateToContainer `
                -DestBlob $Blob.Name `
                -StandardBlobTier 'Hot' `
                -RehydratePriority $RehydratePriority `
                -Context $Blob.Context
            if (-not $destBlob) {
                Write-Error "Failed trying to request rehydrate copy for: $($Blob.Name)"
                return $null
            }

            LogOutput -BlobName $Blob.Name -Message "Rehydrate Copy requested"
            $elapsed = [System.Diagnostics.Stopwatch]::StartNew()

        } catch {
            throw $_
            return $null
        }
    } else {
        LogOutput -BlobName $Blob.Name -Message "Rehydrate Copy already under way"
    }
    #endregion

    while ($destBlob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive') {
        LogOutput -Blobname $destBlob.Name -Message "tier:$($destBlob.ICloudBlob.Properties.StandardBlobTier)...rehydration:$($destBlob.ICloudBlob.Properties.RehydrationStatus) (next update in 10 mins)... "
        Start-Sleep 600 # 10 mins

        $destBlob = Get-AzStorageBlob -Context $Blob.Context -Container $RehydrateToContainer -Blob $Blob.Name
        if (-not $destBlob) {
            LogOutput -BlobName $Blob.Name -Message "Unable to find $($Blob.Name) in $RehydrateToContainer"
            throw "Unable to find $($Blob.Name) in $RehydrateToContainer"
        }
    }

    if ($elapsed) {
        LogOutput -BlobName $destBlob.Name -Message "Rehydration complete. ($($elapsed.Elapsed.ToString()))"
    }
    return $destBlob
}


#####################################################################
function RestoreBlobFromURI {
    param (
        [parameter(Mandatory)]
        [string] $BlobUri
    )

    $uri = [uri] $BlobUri
    $fileName = $uri.Segments[$uri.Segments.Count - 1]

    #region - download blob
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    LogOutput -BlobName $fileName -Message "----- download of $filename to $script:DestinationPath started -----"

    $params = @('copy', $BlobUri, $script:ArchiveTempDir)
    LogOutput -BlobName $fileName -Message "$script:azcopyExe $($params -join ' ') started."
    & $script:azcopyExe $params
    if (-not $?) {
        LogOutput -BlobName $fileName -Message "ERROR - error occurred while downloading $BlobUri"
        Write-Error "ERROR: erorr occurred while downloading blob"
        throw
    }
    LogOutput -BlobName $fileName -Message "----- download of $filename to $script:DestinationPath complete. ($($elapsed.Elapsed.ToString())) -----"
    #endregion

    #region - unzip blob
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    LogOutput -BlobName $fileName -Message "----- unzip of $filename to $script:DestinationPath started -----"

    $params = @('x', $($script:ArchiveTempDir + $fileName), "-o$script:DestinationPath", '-aoa')
    LogOutput -BlobName $fileName -Message "$script:zipExe $($params -join ' ') started. "
    & $script:zipExe $params
    if (-not $?) {
        LogOutput -BlobName $fileName -Message "ERROR: unable to uncompress $($params[1])"
        Write-Error "ERROR: unable to uncompress file"
        throw
    }
    LogOutput -BlobName $fileName -Message "----- unzip of $filename to $script:DestinationPath complete. ($($elapsed.Elapsed.ToString()))  -----"
    #endregion

    if (-not $KeepArchiveFile) {
        Remove-Item "$($script:ArchiveTempDir + $fileName)" -Force
    }
}

#####################################################################

function RestoreBlob {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Blob,

        [Parameter(Mandatory)]
        [string] $RehydratePriority,

        [Parameter()]
        [string] $RehydrateToContainer

    )

    $blobName = $Blob.Name

    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    LogOutput -BlobName $blobName -Message "===== Restore started ====="

    if ($Blob.ICloudBlob.Properties.StandardBlobTier -eq 'Archive') {
        if ($RehydrateToContainer) {
            $blob = RehydrateBlobCopy -Blob $blob -RehydratePriority $RehydratePriority -RehydrateToContainer $RehydrateToContainer
        } else {
            $blob = RehydrateBlob -Blob $blob -RehydratePriority $RehydratePriority
        }

        if (-not $blob) {
            LogOutput -BlobName $($blobName) -Message "Failed to rehydrate $($blobName)"
            return
        }
    }

    $sasToken = New-AzStorageBlobSASToken -CloudBlob $Blob.ICloudBlob -Context $Blob.Context -Permission r -ExpiryTime $((Get-Date).AddDays(7))
    RestoreBlobFromURI -BlobUri $($Blob.ICloudBlob.Uri.Absoluteuri + $sasToken)

    LogOutput -BlobName $blobName -Message "===== Restore complete ($($elapsed.Elapsed.ToString())) ====="
}

#####################################################################
# MAIN

Set-StrictMode -Version 3

#region - validate parameters
# check 7z command path
Write-Progress -Activity "Checking environment..." -Status "validating 7zip"
if ($ZipCommandDir -and -not $ZipCommandDir.EndsWith('\')) {
    $ZipCommandDir += '\'
}
$zipExe = $ZipCommandDir + '7z.exe'
$null = $(& $zipExe)
if (-not $?) {
    throw "Unable to find 7z.exe command. Please make sure 7z.exe is in your PATH or use -ZipCommandDir to specify 7z.exe path"
}

# check azcopy path
Write-Progress -Activity "Checking environment..." -Status "validating AzCopy"
if ($AzCopyCommandDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $AzCopyCommandDir += '\'
}
$azcopyExe = $AzCopyCommandDir + 'azcopy.exe'

# check LogOutputDir
if ($LogOutputDir -and -not $AzCopyCommandDir.EndsWith('\')) {
    $LogOutputDir += '\'
    if (-not $(Test-Path -Path $LogOutputDir)) {
        throw "Unable to find -LogOutputDir $LogOutputDir for writing logs"
    }
}
try {
    $null = Invoke-Expression -Command $azcopyExe -ErrorAction SilentlyContinue
}
catch {
    throw "Unable to find azcopy.exe command. Please make sure azcopy.exe is in your PATH or use -AzCopyCommandDir to specify azcopy.exe path"
}

# check from directories or individual blob
if ($RestoreEmptyDirectories -and $BlobName) {
    throw  "Incompatible parameters -RestoreEmptyDirectories can not be used with -BlobName"
}

if (-not ($RestoreEmptyDirectories -or $BlobName -or $BlobUri))  {
    throw  "-BlobUri, -BlobName or -RestoreEmptyDirectories must be provided"
}

if ($ArchiveTempDir -and -not $ArchiveTempDir.EndsWith('\')) {
    $ArchiveTempDir += '\'
}
if (-not $(Test-Path -Path $ArchiveTempDir)) {
    throw "Unable to find $ArchiveTempDir. Please check the -ArchiveTempDir and try again."
}

# check destination filepath
if ($DestinationPath -and -not $DestinationPath.EndsWith('\')) {
    $DestinationPath += '\'
}
if (-not $(Test-Path -Path $DestinationPath)) {
    try {
        New-Item $DestinationPath -ItemType Directory
    } catch {
        Write-Error "Unable to create directory $DestinationPath - check -DestinationPath and try again."
        throw
    }
}

# login if using managed identities
if ($UseManagedIdentity) {
    Write-Progress -Activity "Checking environment..." -Status "validating Azure environment"
    try {
        $params = @{ }
        if ($Environment) {
            $params = @{'Environment' = $Environment }
        }
        Connect-AzAccount -Identity @params
    }
    catch {
        throw "Unable to login using managed identity."
    }

    # get context & environment
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context.Environment) {
            throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
        }
    }
    catch {
        throw "Please login (Connect-AzAccount) and set the proper subscription context before proceeding."
    }
    $environment = Get-AzEnvironment -Name $context.Environment
}
#endregion

#region - Handle restoring by URL
if ($BlobUri) {
    RestoreBlobFromURI -BlobUri $BlobUri
    return
}
#endregion

#region - verify parameters for $PSCmdlet.ParameterSetName='StorageAccount'
Write-Progress -Activity "Checking environment..." -Status "checking storage container"

try {
    $result = Get-AzContext -ErrorAction Stop
    if (-not $result.Environment) {
        throw "Use of -StorageAccountName parameter set requires logging in your current sessions first. Please use Connect-AzAccount to login and Select-AzSubscriptoin to set the proper subscription context before proceeding."
    }
}
catch {
    throw "Use of -StorageAccountName parameter set requires logging in your current sessions first. Please use Connect-AzAccount to login and Select-AzSubscriptoin to set the proper subscription context before proceeding."
}

$resource = Get-AzResource -ResourceType 'Microsoft.Storage/storageAccounts' -Name $StorageAccountName
if (-not $resource) {
    throw "StorageAccount ($StorageAccountName) not found."
}

$storageAccount = Get-AzStorageAccount -ResourceGroupName $resource.ResourceGroupName -AccountName $StorageAccountName
if (-not $storageAccount) {
    throw "Error getting StorageAccount info $StorageAccountName"
}

$container = Get-AzStorageContainer -Name $ContainerName -Context $storageAccount.context
if (-not $container) {
    throw "Error getting container info for $ContainerName"
}

if ($RehydrateToContainer) {
    $rehydrateContainer = Get-AzStorageContainer -Name $RehydrateToContainer -Context $storageAccount.context
    if (-not $rehydrateContainer) {
        throw "Error getting container info for $RehydrateToContainer"
    }
}


Write-Progress -Activity "Checking environment..." -Completed
#endregion


########## START PROCESSING ##########

$scriptPath = $MyInvocation.InvocationName

# region select Blobs to restore
if ($BlobName) {
    $blobs = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName | Where-Object {$_.Name -like $BlobName}
    if (-not $blobs) {
        Write-Output "No blobs '$BlobName' found in $StorageAccountName/$ContainerName"
        return

    } elseif ($blobs.GetType().IsArray) {
        $blobs = $blobs | ForEach-Object { [PSCustomObject] @{Name = $_.Name; Size = $_.Length; AccessTier = $_.ICloudBlob.Properties.StandardBlobTier }} |
            Out-Gridview -Title "Select archive to restore" -PassThru
        if (-not $blobs) {
            Write-Output "No blobs selected."
            return
        }

    } else {
        RestoreBlob -Blob $blobs -RehydrateToContainer $RehydrateToContainer -RehydratePriority $RehydratePriority
        return
    }

    $archiveBlobNames = $blobs.Name

} elseif ($RestoreEmptyDirectories) {

    # restore blobs from empty directories
    $archiveBlobNames = @()
    $dirs = Get-ChildItem $DestinationPath | Where-Object { $_.PSIsContainer }
    foreach ($dir in $dirs) {
        if ($(Get-ChildItem $dir).Count -eq 0) {
            $archiveBlobNames += $dir.Name + '.7z'
        }
    }

    if (-not $archiveBlobNames) {
        Write-Output "No empty directories found. Nothing to do."
        return
    }

} else {
    Write-Output "-BlobName or -RestoreEmptyDirectories must be provided"

}

# confirm blobs
if (-not ($Force -or $PSCmdlet.ShouldContinue($($archiveBlobNames -join "`n"), "Restore the following files?"))) {
    return # user replied no
}
# endregion

#region - create jobs for each restore
$jobs = @()
foreach ($archiveBlobName in $archiveBlobNames) {
    $blob = Get-AzStorageBlob -Context $storageAccount.Context -Container $ContainerName -Blob $archiveBlobName
    if (-not $blob) {
        throw "Unable to find $archiveBlobName in $ContainerName"
    }

    # skip existing jobs
    $job = Get-Job -Name $archiveBlobName -ErrorAction SilentlyContinue
    if ($job -and $job.State -eq 'Running') {
        LogOutput -BlobName $archiveBlobName "$archiveBlobName (Job:$($job.Id)) already running, staus will be displayed"
        $jobs += $job
        continue
    }

    # create new job
    $scriptBlock = [ScriptBlock]::Create('Param ($p1, $p2, $p3, $p4, $p5, $p6, $p7, $p8) ' + $scriptPath + ' -StorageAccountName $p1 -ContainerName $p2 -BlobName $p3 -DestinationPath $p4 -AzCopyCommandDir $p5 -ZipCommandDir $p6 -ArchiveTempDir $p7 -RehydratePriority $p8')
    $params = @{
        Name         = $archiveBlobName
        ScriptBlock  = $scriptBlock
        ArgumentList = $StorageAccountName, $ContainerName, $archiveBlobName, $($DestinationPath + $(Split-Path $archiveBlobName -LeafBase) + '\'), $AzCopyCommandDir, $ZipCommandDir, $ArchiveTempDir, $RehydratePriority
    }
    # ScriptBlock  = { Param ($p1, $p2, $p3, $p4, $p5, $p6, $p7) .\Restore-BlobArchive.ps1 -StorageAccountName $p1 -ContainerName $p2 -BlobName $p3 -DestinationPath $p4 -AzCopyCommandDir $p5 -ZipCommandDir $p6 -ArchiveTempDir $p7 }
    $jobs += Start-Job @params
    LogOutput -BlobName $archiveBlobName -Message "==================== $archiveBlobName job started ===================="
}
#endregion

#region - display output for all jobs
$sleepInterval = 5
$jobIds = [System.Collections.ArrayList] @($jobs.Id)
Write-Progress -Activity 'Restoring blob archives' -Status ' '
do {
    Start-Sleep -Seconds $sleepInterval

    $CompleteJobIds = @()
    foreach ($jobId in $jobIds) {
        $job = Get-Job -Id $jobId
        if ($job.State -eq 'Running') {
            if ($job.HasMoreData) {
                $sleepInterval = 5
                $job | Receive-Job | ForEach-Object {
                    LogOutput -BlobName $job.name -Message "$_"
                }
                Write-Progress -Id $jobId -Activity $($job.name + '...updated ' + (Get-Date)) -Status ' '
            } else {
                if ($sleepInterval -gt 60) {
                    $sleepInterval = 60
                } else {
                    $sleepInterval += 5
                }
            }
        }
        else {
            $sleepInterval = 5
            $job | Receive-Job | ForEach-Object {
                LogOutput -BlobName $job.name -Message "$_"
            }
            LogOutput -BlobName $job.name "$($job.ChildJobs[0].Error)"
            LogOutput -BlobName $job.name "==================== $($job.Name) $($job.State) $($job.StatusMessage) ===================="
            Remove-Job $job
            $CompleteJobIds += $jobId
        }
    }

    # remove any completed job from array
    foreach ($jobId in $CompleteJobIds) {
        $jobIds.Remove($jobId)
    }
} until (-not $jobIds)
#endregion

Write-Output "Script complete."
