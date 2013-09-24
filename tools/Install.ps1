param($rootPath, $toolsPath, $package, $project)

"*********** Adding template-builder" | Write-Host

$importLabel = "TemplateBuilder"
$targetsPropertyName = "TemplateBuilderTargets"
$targetsFileToAddImport = "ligershark.templates.targets";

# When this package is installed we need to add a property
# to the current project, which points to the
# .targets file in the packages folder

function RemoveExistingKnownPropertyGroups($projectRootElement){
    # if there are any PropertyGroups with a label of "$importLabel" they will be removed here
    $pgsToRemove = @()
    foreach($pg in $projectRootElement.PropertyGroups){
        if($pg.Label -and [string]::Compare($importLabel,$pg.Label,$true) -eq 0) {
            # remove this property group
            $pgsToRemove += $pg
        }
    }

    foreach($pg in $pgsToRemove){
        $pg.Parent.RemoveChild($pg)
    }
}

# TODO: Revisit this later, it was causing some exceptions
function CheckoutProjFileIfUnderScc(){    
    # $sourceControl = Get-Interface $project.DTE.SourceControl ([EnvDTE80.SourceControl2])
    # if($sourceControl.IsItemUnderSCC($project.FullName) -and $sourceControl.IsItemCheckedOut($project.FullName)){
    #    $sourceControl.CheckOutItem($project.FullName)
    #}
    CheckoutIfUnderScc -filePath $project.FullName
}

function CheckoutIfUnderScc(){
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $filePath,

        $project = (Get-Project)
    )
    "`tChecking if file is under source control, [{0}]" -f $filePath| Write-Verbose
    # http://daltskin.blogspot.com/2012/05/nuget-powershell-and-tfs.html
    $sourceControl = Get-Interface $project.DTE.SourceControl ([EnvDTE80.SourceControl2])
    if($sourceControl.IsItemUnderSCC($filePath) -and $sourceControl.IsItemCheckedOut($filePath)){
        "`tChecking out file [{0}]" -f $filePath | Write-Host
        $sourceControl.CheckOutItem($filePath)
    }
}

function EnsureProjectFileIsWriteable(){
    $projItem = Get-ChildItem $project.FullName
    if($projItem.IsReadOnly) {
        "The project file is read-only. Please checkout the project file and re-install this package" | Write-Host -ForegroundColor Red
        throw;
    }
}

function ComputeRelativePathToTargetsFile(){
    param($startPath,$targetPath)   

    # we need to compute the relative path
    $startLocation = Get-Location

    Set-Location $startPath.Directory | Out-Null
    $relativePath = Resolve-Path -Relative $targetPath.FullName

    # reset the location
    Set-Location $startLocation | Out-Null

    return $relativePath
}

function GetSolutionDirFromProj{
    param($msbuildProject)

    if(!$msbuildProject){
        throw "msbuildProject is null"
    }

    $result = $null
    $solutionElement = $null
    foreach($pg in $msbuildProject.PropertyGroups){
        foreach($prop in $pg.Properties){
            if([string]::Compare("SolutionDir",$prop.Name,$true) -eq 0){
                $solutionElement = $prop
                break
            }
        }
    }

    if($solutionElement){
        $result = $solutionElement.Value
    }

    return $result
}

function AddImportElementIfNotExists(){
    param($projectRootElement)

    $foundImport = $false
    $importsToRemove = @()
    foreach($import in $projectRootElement.Imports){
        $importStr = $import.Project
        if(!$importStr){
            $importStr = ""
        }

        $currentLabel = $import.Label
        if(!$currentLabel){
            $currentLabel = ""
        }

        if([string]::Compare($importLabel,$currentLabel.Trim(),$true) -eq 0){
            # found the import no need to continue
            $foundImport = $true
            break
        }
    }

    if(!$foundImport){
        # the import is not in the project, add it
        # <Import Project="$(VsixCompressImport)" Condition="Exists('$(VsizCompressTargets)')" Label="VsixCompress" />
        $importToAdd = $projectRootElement.AddImport("`$($targetsPropertyName)");
        $importToAdd.Condition = "Exists('`$($targetsPropertyName)')"
        $importToAdd.Label = $importLabel 
    }        
}

function UpdateVsixManifest(){
    param(
        $project = (Get-Project)
    )
    # we will look for any file in the project which ends with .vsixmanifest and add
    # <Assets>
    #   <Asset Type="Microsoft.VisualStudio.ItemTemplate" Path="Output\ItemTemplates"/>
    # </Assets>

    $vsixManifestFiles = @()
    # search for any file in the project which ends with .vsixmanifest
    foreach ($projItem in $project.ProjectItems){ 
        if( ($projItem -and $projItem.Name -and $projItem.Name.EndsWith('.vsixmanifest'))) {
            "`tFound manifest [{0}], getting fullpath" -f $projItem.Name | Write-Verbose
            $vsixManifestFiles += $projItem.Properties.Item("FullPath").Value
        }
    }

    foreach($vsixManifestFile in $vsixManifestFiles){
        AddAssetTagToVisxManfiestIfNotExists -vsixFilePathToUpdate $vsixManifestFile
    }
}

function AddAssetTagToVisxManfiestIfNotExists(){
    param(
        [Parameter(Mandatory=$true)]
        $vsixFilePathToUpdate
    )
    
    if(!(Test-Path $vsixFilePathToUpdate)){
        ".vsixmanifest file not found at [{0}]" -f $vsixFilePathToUpdate | Write-Error
        return;
    }
    
    [xml]$vsixXml = (Get-Content $vsixFilePathToUpdate)
    if( ($vsixXml.PackageManifest.Assets.Asset | Where-Object {$_.Path -eq 'Output\ItemTemplates'}) ){
        # if the asset is already there just skip it
        "`t.vsixmanifest not modified because the 'Output\ItemTemplates' element is already in that file" | Write-Host
    }
    else{
        "`tAdding asset tag to .vsixmanifest file {0}" -f $vsixFilePathToUpdate | Write-Host
        CheckoutIfUnderScc -filePath $vsixFilePathToUpdate
        # create the element here
        $newElement = $vsixXml.CreateElement('Asset', $vsixXml.DocumentElement.NamespaceURI)
        $newElement.SetAttribute('Type', 'Microsoft.VisualStudio.ItemTemplate')
        $newElement.SetAttribute('Path', 'Output\ItemTemplates')
        $vsixXml.PackageManifest.Assets.AppendChild($newElement)
        $vsixXml.Save($vsixFilePathToUpdate)
    }
}

#########################
# Start of script here
#########################

$projFile = $project.FullName

# Make sure that the project file exists
if(!(Test-Path $projFile)){
    throw ("Project file not found at [{0}]" -f $projFile)
}

# use MSBuild to load the project and add the property

# This is what we want to add to the project
#  <PropertyGroup Label="VsixCompress">
#    <VsixCompressTargets Condition=" '$(VsixCompressTargets)'=='' ">$([System.IO.Path]::GetFullPath( $(MSBuildProjectDirectory)\..\packages\VsixCompress.1.0.0.6\tools\vsix-compress.targets ))</VsixCompressTargets>
#  </PropertyGroup>

# Before modifying the project save everything so that nothing is lost
$DTE.ExecuteCommand("File.SaveAll")
CheckoutProjFileIfUnderScc
EnsureProjectFileIsWriteable

# Update the Project file to import the .targets file
$relPathToTargets = ComputeRelativePathToTargetsFile -startPath ($projItem = Get-Item $project.FullName) -targetPath (Get-Item ("{0}\tools\{1}" -f $rootPath, $targetsFileToAddImport))

$projectMSBuild = [Microsoft.Build.Construction.ProjectRootElement]::Open($projFile)

RemoveExistingKnownPropertyGroups -projectRootElement $projectMSBuild
$propertyGroup = $projectMSBuild.AddPropertyGroup()
$propertyGroup.Label = $importLabel

$importStmt = ('$([System.IO.Path]::GetFullPath( $(MSBuildProjectDirectory)\{0} ))' -f $relPathToTargets)
$propNuGetImportPath = $propertyGroup.AddProperty($targetsPropertyName, "$importStmt");
$propNuGetImportPath.Condition = ' ''$(TemplateBuilderTargets)''=='''' ';

AddImportElementIfNotExists -projectRootElement $projectMSBuild

$projectMSBuild.Save()

UpdateVsixManifest -project $project

"    TemplateBuilder has been installed into project [{0}]" -f $project.FullName| Write-Host -ForegroundColor DarkGreen
"    `nFor more info how to enable TemplateBuilder on build servers see http://sedodream.com/2013/06/06/HowToSimplifyShippingBuildUpdatesInANuGetPackage.aspx" | Write-Host -ForegroundColor DarkGreen