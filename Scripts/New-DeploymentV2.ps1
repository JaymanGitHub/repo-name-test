Param (
    [string]
    [Parameter(Mandatory = $true)]
    $templateFile,
    
    [string[]]
    [Parameter(Mandatory = $true)]
    $templateParametersFile,
    
    [switch]
    [Parameter(Mandatory = $false)]
    $ParametersDiretory,

    [string]
    [Parameter(Mandatory = $true)]
    $buildInfo,

    [switch]
    [Parameter(Mandatory = $false)]
    $skipTags,

    [string]
    [Parameter(Mandatory = $false, ParameterSetName = 'RG')]
    $resourceGroupName,

    [string]
    [Parameter(Mandatory = $false, ParameterSetName = 'SUB')]
    [Parameter(ParameterSetName = 'MG')]
    $location,

    [switch]
    [Parameter(Mandatory = $false, ParameterSetName = 'SUB')]
    $subscriptionScope,

    [string]
    [Parameter(Mandatory = $false, ParameterSetName = 'RG')]
    [Parameter(ParameterSetName = 'SUB')]
    $subscriptionId,

    [switch]
    [Parameter(Mandatory = $false, ParameterSetName = 'MG')]
    $ManagementGroupScope, 

    [string]
    [Parameter(Mandatory = $false, ParameterSetName = 'MG')]
    $ManagementGroupId
)   

$resourceType = (Get-ChildItem $templateFile).Name.split('.')[0]

Write-Host "Deploying Resource ==> '$($resourceType)' `n --- `n Module to Process: `n $templateFile `n --- `n Config Files to Process: `n $templateParametersFile `n --- `n"

$buildCommitId = $buildInfo.Split(" ")[0].Substring(0, 7)
$buildBranchName = $buildInfo.Split(" ")[1]

$Tags = @{"buildInfo" = "$($buildCommitId)_$($buildBranchName)"; "Tier" = "1" } 


## Path Based Files

if ($ParametersDiretory) {
    
    ## Assess Provided Path
    if (Test-Path -Path $templateParametersFile -PathType Container) {
        
        Write-Host "`n --- `n Detected Path ==> $templateParametersFile"
        ## Transform Path to Files
        $templateParametersFile = Get-ChildItem $templateParametersFile -Recurse -Filter *.parameters.json | Select-Object -ExpandProperty FullName
   
    }## End Assessment for Container
    
}

Write-Host "`n --- `n Processing ==> $($templateParametersFile.Count) Parameter Files"

## Iterate through each file
$fileNo = 1
foreach ($file in $templateParametersFile) {

    Write-Host "`n --- `n Processing Config File Path ==>  $file"
    Write-Host "Config File Name ==> $($file.Split('\')[-1]) `n --- `n"

    [bool]$Stoploop = $false
    [int]$Retrycount = 0

    $CommonDeployParameters = @{
        Name                  = "$($fileNo)_$($resourceType)_$($buildCommitId)_$($buildBranchName)"
        TemplateFile          = $templateFile
        TemplateParameterFile = $file
    }

    ## Append Tags to Parameters if Resource supports them
    if (-not $skipTags) { $CommonDeployParameters += @{Tag = $Tags } }

    ## Attempt deployment
    do {
        try {                            
            Write-Host "`n --- `n Deploying Azure Resource ==> $resourceType `n --- `n"        
            if ($subscriptionScope) {
                Write-Host "Scope ==> Subscription Level Deployment" 

                if (-not $subscriptionId) {
                    Write-Host "Subscription ID not provided. Attempting to retrieve Subscription ID from Parameter File using Scope Property"
                    
                    $subscriptionId_File = (Get-Content $file | ConvertFrom-Json).parameters.scope.value.subscriptionId
                }
                
                if ($subscriptionId) {
                    Write-Host "`n Attempting Deployment using Input from Pipeline `n" 
                    Set-AzContext -SubscriptionId $subscriptionId | out-null
                    New-AzDeployment @CommonDeployParameters -Location $location  
                }
                elseif ($subscriptionId_File) {
                    Write-Host "`n Attempting Deployment using Input from Parameter File`n" 
                    Set-AzContext -SubscriptionId $subscriptionId_File | out-null
                    New-AzDeployment @CommonDeployParameters -Location $location 
                    remove-variable subscriptionId_File          
                }
                else {
                    throw "Unable to Start Deployment, Missing Subscription ID."
                    $Stoploop = $true
                }

            }
            elseif ($ManagementGroupScope) {
                Write-Host "Scope ==> Management Group Level Deployment" 
                
                if (-not $ManagementGroupId) {
                    Write-Host "Management ID not provided. Attempting to retrieve Management Group ID from Parameter File using Scope Property"
                    
                    $ManagementGroupId_File = (Get-Content $file | ConvertFrom-Json).parameters.scope.value.managementGroupId
                }

                if ($ManagementGroupId) {
                    Write-Host "`n Attempting Deployment using Input from Pipeline `n" 
                    New-AzManagementGroupDeployment @CommonDeployParameters -Location $location -ManagementGroupId $ManagementGroupId
                }
                elseif ($ManagementGroupId_File) {
                    Write-Host "`n Attempting Deployment using Input from Parameter File`n" 
                    New-AzManagementGroupDeployment @CommonDeployParameters -Location $location -ManagementGroupId $ManagementGroupId_File
                    remove-variable ManagementGroupId_File          
                }
                else {
                    throw "Unable to Start Deployment, Missing Management Group ID."
                    $Stoploop = $true
                } 
     
            }
            else {
                Write-Host "Scope ==> Resource Group Level Deployment" 
                
                if ($subscriptionId -and $resourceGroupName) {
                    Write-Host "`n Attempting Deployment using Input from Pipeline `n" 
                    Set-AzContext -SubscriptionId $subscriptionId | out-null
                    New-AzResourceGroupDeployment @CommonDeployParameters -ResourceGroupName $resourceGroupName
                }
                elseif (-not ($subscriptionId -and $resourceGroupName)) {
                    Write-Host "`n Attempting Deployment using Input from Parameter File `n" 
                    $subscriptionId_File = (Get-Content $file | ConvertFrom-Json).parameters.scope.value.subscriptionId
                    $resourceGroupName_File = (Get-Content $file | ConvertFrom-Json).parameters.scope.value.resourceGroupName
                    
                    if ($subscriptionId_File -and $resourceGroupName_File) {
                        Set-AzContext -SubscriptionId $subscriptionId_File | out-null
                        New-AzResourceGroupDeployment @CommonDeployParameters -ResourceGroupName $resourceGroupName_File   
                    }
                    else {
                        throw "Unable to Start Deployment, Missing Subscription ID / Resource Group Name"
                        $Stoploop = $true                       
                    } 
                }
                else {
                    throw "Unable to Start Deployment, Missing Subscription ID / Resource Group Name"
                    $Stoploop = $true
                }  
   
            }       
            $Stoploop = $true
        }
        catch {
            if ($Retrycount -gt 1) {
                $PSitem.Exception.Message
                throw "Resource Deployment Failed for file $($file.Split('\')[-1])"
                $Stoploop = $true
            }
            else {
                Write-Host "Resource Deployment with Failed for file $($file.Split('\')[-1]).. Retrying in 30 seconds"
                Start-Sleep -Seconds 30
                $Retrycount = $Retrycount + 1
            }
        }
    }
    While ($Stoploop -eq $false) 

    ++$fileNo
} #end for each file 
