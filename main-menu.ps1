"6" {
    Write-Host "`n" -NoNewline
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Configure Eclipse IDE Settings" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Import module
    $modulePath = Join-Path $PSScriptRoot "modules\ConfigureIDESettings.psm1"
    
    if (-not (Test-Path $modulePath)) {
        Write-Host "`n✗ Module not found: $modulePath" -ForegroundColor Red
        Show-ContinuePrompt
        break
    }
    
    Import-Module $modulePath -Force
    
    # Check if team settings exist
    $teamSettingsPath = Join-Path $PSScriptRoot "config\eclipse-team-settings"
    
    if (-not (Test-Path $teamSettingsPath)) {
        Write-Host "`n✗ Team settings not found!" -ForegroundColor Red
        Write-Host "Team settings need to be exported first." -ForegroundColor Yellow
        Write-Host "`nPlease contact the team lead to export Eclipse settings." -ForegroundColor Gray
        Show-ContinuePrompt
        break
    }
    
    # Prompt user for workspace location
    Write-Host "`nPlease enter your Eclipse workspace path:" -ForegroundColor Yellow
    Write-Host "(Example: C:\Users\YourName\eclipse-workspace)" -ForegroundColor Gray
    Write-Host "Or press Enter to auto-detect" -ForegroundColor Gray
    Write-Host ""
    $workspacePath = Read-Host "Workspace path"
    
    # If empty, try auto-detect
    if ([string]::IsNullOrWhiteSpace($workspacePath)) {
        Write-Host "`nAuto-detecting workspace..." -ForegroundColor Cyan
        $workspaces = Get-EclipseWorkspaces
        
        if ($workspaces.Count -eq 0) {
            Write-Host "✗ No Eclipse workspace found." -ForegroundColor Red
            Write-Host "Please run this again and enter your workspace path manually." -ForegroundColor Yellow
            Show-ContinuePrompt
            break
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
            $workspacePath = $workspaces[[int]$selection - 1]
        }
    }
    
    # Validate workspace path
    if (-not (Test-Path $workspacePath)) {
        Write-Host "`n✗ Workspace not found: $workspacePath" -ForegroundColor Red
        Write-Host "Please verify the path and try again." -ForegroundColor Yellow
        Show-ContinuePrompt
        break
    }
    
    Write-Host "`nUsing workspace: $workspacePath" -ForegroundColor Cyan
    
    # Apply settings
    Write-Host ""
    $result = Import-EclipseTeamSettings -WorkspacePath $workspacePath -Backup
    
    if ($result) {
        Write-Host "`n" -NoNewline
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  ✓ SUCCESS!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Eclipse IDE settings have been configured.`n" -ForegroundColor White
        Write-Host "Workspace: $workspacePath" -ForegroundColor Gray
        Write-Host "`n⚠ IMPORTANT:" -ForegroundColor Yellow
        Write-Host "  Restart Eclipse for changes to take effect" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Green
    }
    else {
        Write-Host "`n✗ Configuration failed." -ForegroundColor Red
        Write-Host "Please check the error messages above." -ForegroundColor Gray
    }
    
    Show-ContinuePrompt
}
```

---

## 🎬 New User Experience

### **User selects option 6:**
```
========================================
  SERS Local Development Setup Tool
========================================
1. Create All Local WebLogic Domains
2. Create a Single WebLogic Domain
3. Apply Team Standardized Configuration to All Domains
4. Apply Team Standardized Configuration to a Domain
5. Configure Required Environment Variables
6. Configure Team IDE Settings              ← Select this
7. Configure Team IDE Code Formatter Style
8. Quit
========================================
Please enter your selection: 6
```

### **User is prompted for workspace:**
```
========================================
  Configure Eclipse IDE Settings
========================================

Please enter your Eclipse workspace path:
(Example: C:\Users\YourName\eclipse-workspace)
Or press Enter to auto-detect

Workspace path: C:\dev\workspace\myproject    ← User types this

Using workspace: C:\dev\workspace\myproject
```

### **Or if they press Enter (auto-detect):**
```
Workspace path:                               ← User presses Enter

Auto-detecting workspace...
✓ Found workspace: C:\Users\JohnDoe\eclipse-workspace

Using workspace: C:\Users\JohnDoe\eclipse-workspace
```

### **Or if multiple workspaces found:**
```
Workspace path:                               ← User presses Enter

Auto-detecting workspace...
Multiple workspaces found:
  [1] C:\Users\JohnDoe\eclipse-workspace
  [2] C:\dev\projects\workspace
  [3] D:\work\workspace

Select workspace (1-3): 2                     ← User selects 2

Using workspace: C:\dev\projects\workspace
```

### **Then settings apply:**
```
[2025-01-21 15:00:00] [Info] ========================================
[2025-01-21 15:00:00] [Info] Importing Eclipse Team Settings
[2025-01-21 15:00:00] [Info] ========================================
[2025-01-21 15:00:00] [Info] Workspace: C:\dev\workspace\myproject
[2025-01-21 15:00:00] [Info] Detected format: EPF

This will overwrite your current Eclipse settings with team settings.
Continue? (Y/N): Y

[2025-01-21 15:00:05] [Success] ✓ Backup created
[2025-01-21 15:00:05] [Success]   ✓ Applied: org.eclipse.jdt.core.prefs
...

========================================
  ✓ SUCCESS!
========================================
Eclipse IDE settings have been configured.

Workspace: C:\dev\workspace\myproject

⚠ IMPORTANT:
  Restart Eclipse for changes to take effect
========================================

Press Enter to continue...
