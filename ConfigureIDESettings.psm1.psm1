#Requires -Version 5.1

<#
.SYNOPSIS
    Module for applying manually exported Eclipse IDE team settings
.DESCRIPTION
    Applies Eclipse settings that were manually exported from a reference Eclipse installation.
    
    Supports two formats:
    1. EPF file (Eclipse Preference File) - exported via File → Export → Preferences
    2. Individual .prefs files - manually copied from .metadata/.plugins/.settings/
    
    Workflow:
    1. Manually export settings from your Eclipse (File → Export → Preferences)
    2. Save to config/eclipse-team-settings/team-preferences.epf
    3. Commit to repository
    4. Other devs run Import-EclipseTeamSettings to apply settings
#>

# Module-level variables
$script:ModuleName = "ConfigureIDESettings"
$script:TeamSettingsPath = "$PSScriptRoot\..\config\eclipse-team-settings"

#region Helper Functions

function Write-ModuleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-EclipseInstallation {
    [CmdletBinding()]
    param(
        [string]$EclipsePath
    )
    
    if (-not $EclipsePath) {
        # Try to find Eclipse in common locations
        $commonPaths = @(
            "$env:ProgramFiles\Eclipse",
            "$env:ProgramFiles(x86)\Eclipse",
            "$env:LOCALAPPDATA\Programs\Eclipse",
            "C:\Eclipse",
            "D:\Eclipse"
        )
        
        foreach ($path in $commonPaths) {
            if (Test-Path "$path\eclipse.exe") {
                return $path
            }
        }
        return $null
    }
    
    if (Test-Path "$EclipsePath\eclipse.exe") {
        return $EclipsePath
    }
    
    return $null
}

function Get-EclipseWorkspaces {
    [CmdletBinding()]
    param()
    
    $workspaces = @()
    
    # Check recent workspaces from Eclipse configuration
    $eclipseConfig = "$env:USERPROFILE\.eclipse"
    if (Test-Path $eclipseConfig) {
        Get-ChildItem -Path $eclipseConfig -Recurse -Filter "*.prefs" -ErrorAction SilentlyContinue | ForEach-Object {
            $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
            if ($content -match 'RECENT_WORKSPACES=(.+)') {
                $workspaces += $matches[1] -split ','
            }
        }
    }
    
    # Also check default workspace location
    $defaultWorkspace = "$env:USERPROFILE\eclipse-workspace"
    if ((Test-Path $defaultWorkspace) -and ($defaultWorkspace -notin $workspaces)) {
        $workspaces += $defaultWorkspace
    }
    
    return $workspaces | Where-Object { Test-Path $_ } | Select-Object -Unique
}

function Get-SettingsDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )
    
    $settingsDir = Join-Path $WorkspacePath ".metadata\.plugins\org.eclipse.core.runtime\.settings"
    
    if (-not (Test-Path $settingsDir)) {
        New-Item -Path $settingsDir -ItemType Directory -Force | Out-Null
    }
    
    return $settingsDir
}

function Get-TeamSettingsFormat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath
    )
    
    # Check if EPF file exists
    $epfFiles = Get-ChildItem -Path $SettingsPath -Filter "*.epf" -File -ErrorAction SilentlyContinue
    if ($epfFiles.Count -gt 0) {
        return @{
            Format = 'EPF'
            File = $epfFiles[0].FullName
        }
    }
    
    # Check if .prefs files exist
    $prefsFiles = Get-ChildItem -Path $SettingsPath -Filter "*.prefs" -File -ErrorAction SilentlyContinue
    if ($prefsFiles.Count -gt 0) {
        return @{
            Format = 'PREFS'
            Files = $prefsFiles
        }
    }
    
    return $null
}

#endregion

#region Import Functions

function Import-EclipseEPFFile {
    <#
    .SYNOPSIS
        Import settings from EPF file (Eclipse Preference File)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,
        
        [Parameter(Mandatory)]
        [string]$EpfFilePath,
        
        [switch]$Backup
    )
    
    Write-ModuleLog "Importing from EPF file: $EpfFilePath" -Level Info
    
    if (-not (Test-Path $EpfFilePath)) {
        throw "EPF file not found: $EpfFilePath"
    }
    
    # Backup if requested
    if ($Backup) {
        $settingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
        $backupDir = Join-Path $WorkspacePath ".metadata\.settings-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        if (Test-Path $settingsDir) {
            Write-ModuleLog "Creating backup..." -Level Info
            Copy-Item -Path $settingsDir -Destination $backupDir -Recurse -Force
            Write-ModuleLog "✓ Backup created: $backupDir" -Level Success
        }
    }
    
    # Parse EPF file and apply settings
    $epfContent = Get-Content $EpfFilePath -Raw
    
    # EPF format: /instance/plugin.id/key=value
    # We need to convert this to .prefs files
    
    $settingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
    $pluginSettings = @{}
    
    # Parse EPF content
    $lines = $epfContent -split "`n"
    foreach ($line in $lines) {
        $line = $line.Trim()
        
        # Skip comments and empty lines
        if ($line.StartsWith('#') -or [string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        
        # Parse setting lines: /instance/plugin.id/key=value
        if ($line -match '^/instance/([^/]+)/(.+)=(.*)$') {
            $pluginId = $matches[1]
            $key = $matches[2]
            $value = $matches[3]
            
            if (-not $pluginSettings.ContainsKey($pluginId)) {
                $pluginSettings[$pluginId] = @()
            }
            
            $pluginSettings[$pluginId] += "$key=$value"
        }
    }
    
    # Write settings to .prefs files
    $appliedCount = 0
    foreach ($plugin in $pluginSettings.GetEnumerator()) {
        $prefsFile = Join-Path $settingsDir "$($plugin.Key).prefs"
        
        $content = "eclipse.preferences.version=1`n"
        $content += ($plugin.Value -join "`n")
        
        Set-Content -Path $prefsFile -Value $content -Force -Encoding UTF8
        Write-ModuleLog "  ✓ Applied: $($plugin.Key).prefs" -Level Success
        $appliedCount++
    }
    
    Write-ModuleLog "✓ Imported $appliedCount preference files from EPF" -Level Success
    return $appliedCount
}

function Import-EclipsePrefsFiles {
    <#
    .SYNOPSIS
        Import settings from individual .prefs files
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath,
        
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [switch]$Backup
    )
    
    Write-ModuleLog "Importing from .prefs files: $SourcePath" -Level Info
    
    # Backup if requested
    if ($Backup) {
        $settingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
        $backupDir = Join-Path $WorkspacePath ".metadata\.settings-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        if (Test-Path $settingsDir) {
            Write-ModuleLog "Creating backup..." -Level Info
            Copy-Item -Path $settingsDir -Destination $backupDir -Recurse -Force
            Write-ModuleLog "✓ Backup created: $backupDir" -Level Success
        }
    }
    
    # Get destination directory
    $destSettingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
    
    # Get all .prefs files from source
    $prefsFiles = Get-ChildItem -Path $SourcePath -Filter "*.prefs" -File
    
    if ($prefsFiles.Count -eq 0) {
        throw "No .prefs files found in: $SourcePath"
    }
    
    Write-ModuleLog "Found $($prefsFiles.Count) preference files to import" -Level Info
    
    # Copy each file
    $importedCount = 0
    foreach ($prefsFile in $prefsFiles) {
        $targetFile = Join-Path $destSettingsDir $prefsFile.Name
        
        Copy-Item -Path $prefsFile.FullName -Destination $targetFile -Force
        Write-ModuleLog "  ✓ Imported: $($prefsFile.Name)" -Level Success
        $importedCount++
    }
    
    return $importedCount
}

function Import-EclipseTeamSettings {
    <#
    .SYNOPSIS
        Import team settings to Eclipse workspace (auto-detects format)
    .DESCRIPTION
        Automatically detects and imports Eclipse settings from either:
        - EPF file (exported via File → Export → Preferences)
        - Individual .prefs files (manually copied)
    .EXAMPLE
        Import-EclipseTeamSettings -Backup
    .EXAMPLE
        Import-EclipseTeamSettings -WorkspacePath "C:\workspace" -SettingsPath ".\custom-settings"
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$WorkspacePath,
        
        [Parameter()]
        [string]$SettingsPath = $script:TeamSettingsPath,
        
        [switch]$Backup,
        
        [switch]$Force
    )
    
    begin {
        Write-ModuleLog "========================================" -Level Info
        Write-ModuleLog "Importing Eclipse Team Settings" -Level Info
        Write-ModuleLog "========================================" -Level Info
    }
    
    process {
        try {
            # Auto-detect workspace if not provided
            if (-not $WorkspacePath) {
                $workspaces = Get-EclipseWorkspaces
                if ($workspaces.Count -eq 0) {
                    throw "No Eclipse workspace found. Please specify -WorkspacePath parameter."
                }
                
                if ($workspaces.Count -eq 1) {
                    $WorkspacePath = $workspaces[0]
                    Write-ModuleLog "Auto-detected workspace: $WorkspacePath" -Level Info
                }
                else {
                    Write-ModuleLog "Multiple workspaces found:" -Level Info
                    for ($i = 0; $i -lt $workspaces.Count; $i++) {
                        Write-Host "  [$($i+1)] $($workspaces[$i])"
                    }
                    
                    $selection = Read-Host "`nSelect workspace (1-$($workspaces.Count))"
                    $WorkspacePath = $workspaces[[int]$selection - 1]
                }
            }
            
            # Validate workspace
            if (-not (Test-Path $WorkspacePath)) {
                throw "Workspace not found: $WorkspacePath"
            }
            
            # Validate settings source
            if (-not (Test-Path $SettingsPath)) {
                throw "Team settings not found at: $SettingsPath`n`nPlease ensure settings have been exported first:`n  1. In Eclipse: File → Export → Preferences`n  2. Save to: $SettingsPath\team-preferences.epf"
            }
            
            Write-ModuleLog "Workspace: $WorkspacePath" -Level Info
            Write-ModuleLog "Settings source: $SettingsPath" -Level Info
            Write-ModuleLog "----------------------------------------" -Level Info
            
            # Detect settings format
            $settingsInfo = Get-TeamSettingsFormat -SettingsPath $SettingsPath
            
            if (-not $settingsInfo) {
                throw "No valid settings found in $SettingsPath`n`nExpected either:`n  - .epf file (from File → Export → Preferences)`n  - .prefs files (from .metadata\.plugins\.settings\)"
            }
            
            Write-ModuleLog "Detected format: $($settingsInfo.Format)" -Level Info
            
            # Prompt for confirmation if not forced
            if (-not $Force) {
                Write-Host "`nThis will overwrite your current Eclipse settings with team settings." -ForegroundColor Yellow
                
                if ($settingsInfo.Format -eq 'EPF') {
                    Write-Host "Source: $($settingsInfo.File)" -ForegroundColor Yellow
                } else {
                    Write-Host "Files to import: $($settingsInfo.Files.Count)" -ForegroundColor Yellow
                }
                
                $confirm = Read-Host "Continue? (Y/N)"
                
                if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                    Write-ModuleLog "Import cancelled by user" -Level Warning
                    return $false
                }
            }
            
            Write-ModuleLog "----------------------------------------" -Level Info
            
            # Import based on format
            $importedCount = 0
            
            if ($settingsInfo.Format -eq 'EPF') {
                $importedCount = Import-EclipseEPFFile `
                    -WorkspacePath $WorkspacePath `
                    -EpfFilePath $settingsInfo.File `
                    -Backup:$Backup
            }
            else {
                $importedCount = Import-EclipsePrefsFiles `
                    -WorkspacePath $WorkspacePath `
                    -SourcePath $SettingsPath `
                    -Backup:$Backup
            }
            
            Write-ModuleLog "========================================" -Level Info
            Write-ModuleLog "✓ Successfully imported $importedCount settings" -Level Success
            Write-ModuleLog "========================================" -Level Info
            Write-ModuleLog "IMPORTANT: Restart Eclipse for changes to take effect" -Level Warning
            Write-ModuleLog "========================================" -Level Info
            
            return $true
        }
        catch {
            Write-ModuleLog "Error during import: $_" -Level Error
            Write-ModuleLog $_.ScriptStackTrace -Level Error
            return $false
        }
    }
}

#endregion

#region Validation Functions

function Test-EclipseSettingsApplied {
    <#
    .SYNOPSIS
        Validates that team settings have been applied correctly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )
    
    Write-ModuleLog "Validating Eclipse settings..." -Level Info
    Write-ModuleLog "----------------------------------------" -Level Info
    
    $settingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
    
    if (-not (Test-Path $settingsDir)) {
        Write-ModuleLog "Settings directory not found" -Level Error
        return $false
    }
    
    # Check for key settings files
    $keySettings = @(
        'org.eclipse.jdt.core.prefs',
        'org.eclipse.jdt.ui.prefs',
        'org.eclipse.ui.editors.prefs',
        'org.eclipse.core.resources.prefs'
    )
    
    $allPresent = $true
    $presentCount = 0
    
    foreach ($setting in $keySettings) {
        $settingFile = Join-Path $settingsDir $setting
        $exists = Test-Path $settingFile
        
        if ($exists) {
            Write-Host "  ✓ $setting" -ForegroundColor Green
            $presentCount++
        }
        else {
            Write-Host "  ✗ $setting - MISSING" -ForegroundColor Red
            $allPresent = $false
        }
    }
    
    Write-ModuleLog "----------------------------------------" -Level Info
    Write-ModuleLog "Found: $presentCount / $($keySettings.Count) key settings" -Level Info
    
    if ($allPresent) {
        Write-ModuleLog "✓ All key settings are applied!" -Level Success
        return $true
    }
    else {
        Write-ModuleLog "Some settings are missing. Run Import-EclipseTeamSettings" -Level Warning
        return $false
    }
}

function Show-EclipseSettingsSummary {
    <#
    .SYNOPSIS
        Displays a summary of configured Eclipse settings
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )
    
    $settingsDir = Get-SettingsDirectory -WorkspacePath $WorkspacePath
    
    if (-not (Test-Path $settingsDir)) {
        Write-ModuleLog "No settings found in workspace" -Level Warning
        return
    }
    
    Write-ModuleLog "Eclipse Settings Summary" -Level Info
    Write-ModuleLog "========================================" -Level Info
    Write-ModuleLog "Workspace: $WorkspacePath" -Level Info
    Write-ModuleLog "----------------------------------------" -Level Info
    
    $prefsFiles = Get-ChildItem -Path $settingsDir -Filter "*.prefs" -File
    
    if ($prefsFiles.Count -eq 0) {
        Write-ModuleLog "No preference files found" -Level Warning
        return
    }
    
    $categories = @{
        'Java Development' = @('org.eclipse.jdt.core', 'org.eclipse.jdt.ui', 'org.eclipse.jdt.launching')
        'Editor' = @('org.eclipse.ui.editors', 'org.eclipse.ui.workbench.texteditor')
        'Workspace' = @('org.eclipse.core.resources', 'org.eclipse.core.runtime')
        'Build Tools' = @('org.eclipse.m2e.core', 'org.eclipse.buildship')
        'Version Control' = @('org.eclipse.egit', 'org.eclipse.team')
    }
    
    foreach ($category in $categories.GetEnumerator()) {
        $found = $prefsFiles | Where-Object { 
            $fileName = $_.Name
            $category.Value | Where-Object { $fileName -like "$_*" }
        }
        
        if ($found) {
            Write-Host "`n$($category.Key):" -ForegroundColor Cyan
            foreach ($file in $found) {
                Write-Host "  ✓ $($file.Name)" -ForegroundColor Green
            }
        }
    }
    
    Write-ModuleLog "`n========================================" -Level Info
    Write-ModuleLog "Total preference files: $($prefsFiles.Count)" -Level Info
}

function Show-TeamSettingsInfo {
    <#
    .SYNOPSIS
        Shows information about team settings in the repository
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SettingsPath = $script:TeamSettingsPath
    )
    
    Write-ModuleLog "Team Settings Information" -Level Info
    Write-ModuleLog "========================================" -Level Info
    
    if (-not (Test-Path $SettingsPath)) {
        Write-ModuleLog "No team settings found at: $SettingsPath" -Level Warning
        Write-ModuleLog "`nTo create team settings:" -Level Info
        Write-ModuleLog "  1. Configure Eclipse with desired settings" -Level Info
        Write-ModuleLog "  2. In Eclipse: File → Export → Preferences" -Level Info
        Write-ModuleLog "  3. Save to: $SettingsPath\team-preferences.epf" -Level Info
        return
    }
    
    Write-ModuleLog "Settings path: $SettingsPath" -Level Info
    Write-ModuleLog "----------------------------------------" -Level Info
    
    $settingsInfo = Get-TeamSettingsFormat -SettingsPath $SettingsPath
    
    if (-not $settingsInfo) {
        Write-ModuleLog "No valid settings found" -Level Warning
        return
    }
    
    if ($settingsInfo.Format -eq 'EPF') {
        Write-Host "Format: EPF (Eclipse Preference File)" -ForegroundColor Cyan
        Write-Host "File: $($settingsInfo.File)" -ForegroundColor Gray
        
        $fileSize = (Get-Item $settingsInfo.File).Length
        Write-Host "Size: $([math]::Round($fileSize/1KB, 2)) KB" -ForegroundColor Gray
        
        $lastModified = (Get-Item $settingsInfo.File).LastWriteTime
        Write-Host "Last modified: $($lastModified.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
    }
    else {
        Write-Host "Format: Individual .prefs files" -ForegroundColor Cyan
        Write-Host "Files: $($settingsInfo.Files.Count)" -ForegroundColor Gray
        
        $totalSize = ($settingsInfo.Files | Measure-Object -Property Length -Sum).Sum
        Write-Host "Total size: $([math]::Round($totalSize/1KB, 2)) KB" -ForegroundColor Gray
    }
    
    # Check for README
    $readmeFile = Join-Path $SettingsPath "README.md"
    if (Test-Path $readmeFile) {
        Write-Host "`n✓ README.md present" -ForegroundColor Green
    }
    
    Write-ModuleLog "========================================" -Level Info
}

#endregion

#region Main Convenience Function

function Initialize-EclipseIDESettings {
    <#
    .SYNOPSIS
        Main function for menu integration - handles user prompts and applies settings
    .DESCRIPTION
        This is the primary entry point for the menu system. It:
        - Validates team settings exist
        - Prompts user for workspace path (with auto-detect option)
        - Validates workspace
        - Applies team settings with backup
    .EXAMPLE
        Initialize-EclipseIDESettings
    #>
    [CmdletBinding()]
    param()
    
    begin {
        Write-Host "`n" -NoNewline
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Configure Eclipse IDE Settings" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Cyan
    }
    
    process {
        try {
            # Check if team settings exist
            if (-not (Test-Path $script:TeamSettingsPath)) {
                Write-Host "`n✗ Team settings not found!" -ForegroundColor Red
                Write-Host "Location: $script:TeamSettingsPath" -ForegroundColor Gray
                Write-Host "`nTeam settings need to be exported first:" -ForegroundColor Yellow
                Write-Host "  1. Configure Eclipse with desired settings" -ForegroundColor Gray
                Write-Host "  2. In Eclipse: File → Export → Preferences" -ForegroundColor Gray
                Write-Host "  3. Save to: $script:TeamSettingsPath\team-preferences.epf" -ForegroundColor Gray
                Write-Host "`nPlease contact the team lead." -ForegroundColor Yellow
                return $false
            }
            
            # Show team settings info
            $settingsInfo = Get-TeamSettingsFormat -SettingsPath $script:TeamSettingsPath
            
            if (-not $settingsInfo) {
                Write-Host "`n✗ Invalid team settings format!" -ForegroundColor Red
                Write-Host "Expected EPF file or .prefs files in: $script:TeamSettingsPath" -ForegroundColor Gray
                return $false
            }
            
            Write-Host "`n✓ Team settings found" -ForegroundColor Green
            if ($settingsInfo.Format -eq 'EPF') {
                Write-Host "Format: EPF (Eclipse Preference File)" -ForegroundColor Gray
                $fileName = Split-Path $settingsInfo.File -Leaf
                Write-Host "File: $fileName" -ForegroundColor Gray
            } else {
                Write-Host "Format: Individual .prefs files" -ForegroundColor Gray
                Write-Host "Files: $($settingsInfo.Files.Count)" -ForegroundColor Gray
            }
            
            # Prompt for workspace path
            Write-Host "`n" -NoNewline
            Write-Host "Please enter your Eclipse workspace path:" -ForegroundColor Yellow
            Write-Host "(Example: C:\Users\YourName\eclipse-workspace)" -ForegroundColor Gray
            Write-Host "Or press Enter to auto-detect" -ForegroundColor Gray
            Write-Host ""
            $workspacePath = Read-Host "Workspace path"
            
            # Handle auto-detect
            if ([string]::IsNullOrWhiteSpace($workspacePath)) {
                Write-Host "`nAuto-detecting workspace..." -ForegroundColor Cyan
                $workspaces = Get-EclipseWorkspaces
                
                if ($workspaces.Count -eq 0) {
                    Write-Host "✗ No Eclipse workspace found." -ForegroundColor Red
                    Write-Host "`nPlease ensure Eclipse has been run at least once," -ForegroundColor Yellow
                    Write-Host "or run this option again and enter the path manually." -ForegroundColor Yellow
                    return $false
                }
                elseif ($workspaces.Count -eq 1) {
                    $workspacePath = $workspaces[0]
                    Write-Host "✓ Found workspace: $workspacePath" -ForegroundColor Green
                }
                else {
                    Write-Host "Multiple workspaces found:" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $workspaces.Count; $i++) {
                        Write-Host "  [$($i+1)] $($workspaces[$i])"
                    }
                    
                    $selection = Read-Host "`nSelect workspace (1-$($workspaces.Count))"
                    
                    if ([int]$selection -lt 1 -or [int]$selection -gt $workspaces.Count) {
                        Write-Host "✗ Invalid selection." -ForegroundColor Red
                        return $false
                    }
                    
                    $workspacePath = $workspaces[[int]$selection - 1]
                }
            }
            
            # Validate workspace path
            if (-not (Test-Path $workspacePath)) {
                Write-Host "`n✗ Workspace not found: $workspacePath" -ForegroundColor Red
                Write-Host "Please verify the path and try again." -ForegroundColor Yellow
                return $false
            }
            
            # Check if it's a valid Eclipse workspace
            $metadataPath = Join-Path $workspacePath ".metadata"
            if (-not (Test-Path $metadataPath)) {
                Write-Host "`n✗ Not a valid Eclipse workspace: $workspacePath" -ForegroundColor Red
                Write-Host "The .metadata folder is missing." -ForegroundColor Yellow
                Write-Host "Please ensure this is an Eclipse workspace that has been opened at least once." -ForegroundColor Yellow
                return $false
            }
            
            Write-Host "`nUsing workspace: $workspacePath" -ForegroundColor Cyan
            
            # Apply settings
            Write-Host ""
            $result = Import-EclipseTeamSettings -WorkspacePath $workspacePath -Backup -Force
            
            if ($result) {
                Write-Host "`n" -NoNewline
                Write-Host "========================================" -ForegroundColor Green
                Write-Host "  ✓ SUCCESS!" -ForegroundColor Green
                Write-Host "========================================" -ForegroundColor Green
                Write-Host "Eclipse IDE settings have been configured.`n" -ForegroundColor White
                Write-Host "Workspace: $workspacePath" -ForegroundColor Gray
                Write-Host "`n⚠ IMPORTANT:" -ForegroundColor Yellow
                Write-Host "  Close Eclipse completely and restart" -ForegroundColor Yellow
                Write-Host "  for all changes to take effect" -ForegroundColor Yellow
                Write-Host "========================================" -ForegroundColor Green
                return $true
            }
            else {
                Write-Host "`n✗ Configuration failed." -ForegroundColor Red
                Write-Host "Please check the error messages above." -ForegroundColor Gray
                return $false
            }
        }
        catch {
            Write-ModuleLog "Unexpected error: $_" -Level Error
            return $false
        }
    }
}

#endregion

#region Export Module Members

Export-ModuleMember -Function @(
    # Main functions
    'Initialize-EclipseIDESettings',
    'Import-EclipseTeamSettings',
    
    # Validation and info
    'Test-EclipseSettingsApplied',
    'Show-EclipseSettingsSummary',
    'Show-TeamSettingsInfo',
    
    # Utilities
    'Get-EclipseWorkspaces'
)

#endregion
