<#
.SYNOPSIS
    oh-my-psmux installer — glamorous, gum-powered setup for Windows.
.DESCRIPTION
    Interactive one-shot installer that:
      1. Bootstraps Gum (downloads a portable copy if not already installed)
      2. Detects and optionally installs psmux (via winget / scoop / choco)
      3. Installs oh-my-psmux.ps1 into your PowerShell profile
      4. Writes a themed ~/.psmux.conf with a curated plugin set
      5. Optionally configures Windows Terminal as the default host
    Every prompt uses Gum, so the installer looks and feels like a
    modern TUI rather than a bare Read-Host prompt.
.PARAMETER InstallDir
    Where to drop oh-my-psmux.ps1. Defaults to
    "$HOME\Documents\PowerShell\Scripts".
.PARAMETER Uninstall
    Reverse the installation: remove the profile block, config, and
    (optionally) psmux itself.
.PARAMETER Yes
    Skip every confirmation prompt (non-interactive / CI mode).
.EXAMPLE
    irm https://raw.githubusercontent.com/your-org/oh-my-psmux/main/install.ps1 | iex
.EXAMPLE
    .\install.ps1 -InstallDir "D:\scripts" -Yes
.NOTES
    Requires : PowerShell 7+, Windows 10/11
    Install  : winget install charmbracelet.gum
    Docs     : https://github.com/charmbracelet/gum  |  https://github.com/psmux/psmux
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    [string] $InstallDir = "$HOME\Documents\PowerShell\Scripts",
    [switch] $Uninstall,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ======================================================================
# 0. Constants
# ======================================================================

$SCRIPT_VERSION   = '1.0.0'
$OH_MY_PSMUX_URL  = 'https://raw.githubusercontent.com/your-org/oh-my-psmux/main/oh-my-psmux.ps1'
$PROFILE_MARKER_B = '# >>> oh-my-psmux >>>'
$PROFILE_MARKER_E = '# <<< oh-my-psmux <<<'
$GUM_VERSION      = 'latest'

# Colour palette (gum accepts hex, ANSI-256, or named colours)
$C = @{
    Primary   = '212'   # pink
    Secondary = '99'    # purple
    Accent    = '86'    # cyan
    Success   = '42'    # green
    Warning   = '214'   # orange
    Danger    = '196'   # red
    Muted     = '240'   # grey
    Text      = '252'   # light grey
}

# ======================================================================
# 1. Gum bootstrap (must run before anything else)
# ======================================================================

function Initialize-Gum {
    # Already on PATH?
    if (Get-Command gum -ErrorAction SilentlyContinue) {
        return (Get-Command gum).Source
    }

    # Try winget / scoop silently first
    $installers = @(
        @{ Name = 'winget'; Args = @('install','--id=charmbracelet.gum','-e','--silent','--accept-source-agreements','--accept-package-agreements') },
        @{ Name = 'scoop';  Args = @('install','charm-gum') }
    )
    foreach ($i in $installers) {
        if (Get-Command $i.Name -ErrorAction SilentlyContinue) {
            try {
                & $i.Name @($i.Args) 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    # Refresh PATH so Get-Command finds it
                    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                                [Environment]::GetEnvironmentVariable('Path','User')
                    if (Get-Command gum -ErrorAction SilentlyContinue) {
                        return (Get-Command gum).Source
                    }
                }
            } catch { }
        }
    }

    # Fallback: download the portable zip straight from GitHub
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x86_64' } else { 'i386' }
    $tmp  = Join-Path $env:TEMP "gum-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/charmbracelet/gum/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'oh-my-psmux-installer' }
    $asset   = $release.assets | Where-Object { $_.name -match "windows_$arch\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw 'Could not find a Windows gum release asset.' }

    $zip = Join-Path $tmp 'gum.zip'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp -Force

    $exe = Get-ChildItem -Path $tmp -Recurse -Filter 'gum.exe' | Select-Object -First 1
    if (-not $exe) { throw 'gum.exe not found in the downloaded archive.' }

    # Stash it in %LOCALAPPDATA%\Programs\gum for stability
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\gum'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Copy-Item $exe.FullName (Join-Path $dest 'gum.exe') -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

    # Add to user PATH permanently
    $userPath = [Environment]::GetEnvironmentVariable('Path','User') -split ';'
    if ($userPath -notcontains $dest) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath + $dest) -join ';', 'User')
    }
    $env:Path += ";$dest"

    return (Join-Path $dest 'gum.exe')
}

try {
    $GumExe = Initialize-Gum
} catch {
    Write-Host "Failed to bootstrap gum: $_" -ForegroundColor Red
    exit 1
}

# Shortcut wrapper — always calls the resolved gum binary
function gum { & $script:GumExe @args }

# ======================================================================
# 2. Gum UI helpers
# ======================================================================

function Show-Banner {
    $art = @'
   ___  _   _     __  __         ___         _
  / _ \| | | |   |  \/  |_  _   | _ \_  _ __| |_ _ __
 | (_) | |_| |   | |\/| | || |  |  _/ || (_-<  _| '  \
  \___/ \___/    |_|  |_|\_, |  |_|  \_, /__/\__|_|_|_|
                         |__/        |__/
'@
    gum style `
        --border double `
        --border-foreground $C.Primary `
        --foreground $C.Accent `
        --padding "1 4" `
        --margin "1 2" `
        --align center `
        $art "`noh-my-psmux installer  v$SCRIPT_VERSION`n"
}

function Show-Step {
    param([string] $Title, [string] $Subtitle = '')
    Write-Host ''
    gum style --foreground $C.Primary --bold "  ▸ $Title"
    if ($Subtitle) {
        gum style --foreground $C.Muted --italic "    $Subtitle"
    }
}

function Show-Success { param([string] $Msg) gum style --foreground $C.Success "  ✓ $Msg" }
function Show-Warn    { param([string] $Msg) gum style --foreground $C.Warning "  ! $Msg" }
function Show-Error   { param([string] $Msg) gum style --foreground $C.Danger  "  ✗ $Msg" }
function Show-Info    { param([string] $Msg) gum style --foreground $C.Accent  "  ℹ $Msg" }
function Show-Muted   { param([string] $Msg) gum style --foreground $C.Muted   "    $Msg" }

function Confirm-Action {
    param([string] $Prompt, [switch] $DefaultYes)
    if ($Yes) { return $true }
    $default = if ($DefaultYes) { '--default=yes' } else { '--default=no' }
    gum confirm --prompt.foreground $C.Accent --selected.background $C.Primary @($default -split '=')[0] ($default -replace '.*=','') "$Prompt"
    return ($LASTEXITCODE -eq 0)
}

function Ask-Input {
    param([string] $Prompt, [string] $Placeholder = '', [string] $Default = '')
    if ($Yes -and $Default) { return $Default }
    $args = @('input', '--prompt', "$Prompt ", '--prompt.foreground', $C.Accent, '--cursor.foreground', $C.Primary)
    if ($Placeholder) { $args += @('--placeholder', $Placeholder) }
    if ($Default)     { $args += @('--value', $Default) }
    return (gum @args)
}

function Ask-Choose {
    param([string] $Prompt, [string[]] $Options, [string] $Default = '')
    $args = @('choose', '--header', "  $Prompt", '--header.foreground', $C.Accent,
              '--cursor.foreground', $C.Primary, '--selected.foreground', $C.Primary)
    if ($Default) { $args += @('--selected', $Default) }
    $args += $Options
    return (gum @args)
}

function Invoke-WithSpin {
    param([string] $Title, [scriptblock] $Action)
    $tmp = [IO.Path]::GetTempFileName()
    Set-Content -Path $tmp -Value "& { $($Action.ToString()) } > `"$tmp.log`" 2>&1; exit `$LASTEXITCODE" -ErrorAction SilentlyContinue
    # Simpler: run the scriptblock and capture its exit code
    $job = Start-Job -ScriptBlock $Action
    gum spin --spinner dot --spinner.foreground $C.Primary --title "  $Title" -- sleep 1000 | Out-Null
    Wait-Job $job | Out-Null
    $out = Receive-Job $job
    Remove-Job $job -Force
    return $out
}

# A spinner that wraps an external command (gum's -- cmd form)
function Run-Spinner {
    param([string] $Title, [scriptblock] $Action)
    if ($Yes) {
        # Non-interactive: just run it
        & $Action
        return $LASTEXITCODE
    }
    $tmpOut = Join-Path $env:TEMP "omp-spin-$(Get-Random).log"
    $code = 0
    gum spin --spinner dot --spinner.foreground $C.Primary --title "  $Title" -- pwsh -NoProfile -Command "& { $($Action.ToString()) }" *> $tmpOut
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Get-Content $tmpOut -ErrorAction SilentlyContinue | ForEach-Object { Show-Muted $_ }
    }
    Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
    return $code
}

# ======================================================================
# 3. Prerequisite checks
# ======================================================================

function Test-Prerequisites {
    Show-Step 'Checking prerequisites'

    $ok = $true

    # PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Show-Error "PowerShell 7+ required (you have $($PSVersionTable.PSVersion))"
        Show-Muted '  Install: winget install --id Microsoft.PowerShell'
        $ok = $false
    } else {
        Show-Success "PowerShell $($PSVersionTable.PSVersion)"
    }

    # Windows version
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        Show-Success "$($os.Caption) (build $($os.BuildNumber))"
    }

    # psmux presence
    $psmuxVer = $null
    try { $psmuxVer = (& psmux -V 2>$null).Trim() } catch { }
    if (-not $psmuxVer) {
        try { $psmuxVer = (& tmux -V 2>$null).Trim() } catch { }
    }
    if ($psmuxVer) {
        Show-Success "psmux detected: $psmuxVer"
    } else {
        Show-Warn 'psmux not found — will offer to install it'
    }

    # winget presence
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Show-Success 'winget available'
    } else {
        Show-Warn 'winget not found — will fall back to scoop/choco'
    }

    return $ok
}

# ======================================================================
# 4. psmux installation
# ======================================================================

function Install-Psmux {
    Show-Step 'Installing psmux'

    $channel = Ask-Choose -Prompt 'Choose an install channel for psmux:' `
        -Options @('winget (recommended)', 'scoop', 'chocolatey', 'cargo', 'Skip — already installed')

    switch -Regex ($channel) {
        '^winget' {
            Run-Spinner 'Installing psmux via winget...' {
                winget install --id psmux -e --silent `
                    --accept-source-agreements --accept-package-agreements | Out-Null
            } | Out-Null
        }
        '^scoop' {
            Run-Spinner 'Adding psmux bucket...' {
                scoop bucket add psmux https://github.com/psmux/scoop-psmux 2>$null | Out-Null
            } | Out-Null
            Run-Spinner 'Installing psmux via scoop...' { scoop install psmux | Out-Null } | Out-Null
        }
        '^chocolatey' {
            Run-Spinner 'Installing psmux via choco...' { choco install psmux -y | Out-Null } | Out-Null
        }
        '^cargo' {
            Run-Spinner 'Building psmux from crates.io...' { cargo install psmux | Out-Null } | Out-Null
        }
        '^Skip' {
            Show-Info 'Skipping psmux install'
            return
        }
    }

    # Refresh PATH and verify
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
    try {
        $v = (& psmux -V 2>$null).Trim()
        if ($v) { Show-Success "psmux installed: $v" }
        else    { Show-Warn 'psmux command not found on PATH yet — restart your shell later.' }
    } catch {
        Show-Warn 'psmux not on PATH yet — restart your shell later.'
    }
}

# ======================================================================
# 5. Profile integration
# ======================================================================

function Write-ProfileBlock {
    param([string] $ScriptPath)

    Show-Step 'Wiring up your PowerShell profile'

    $profileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }

    $content = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if (-not $content) { $content = '' }

    $block = @"
$PROFILE_MARKER_B
# oh-my-psmux — auto-generated by install.ps1
. "$ScriptPath"
$PROFILE_MARKER_E
"@

    if ($content -match [regex]::Escape($PROFILE_MARKER_B)) {
        $pattern = [regex]::Escape($PROFILE_MARKER_B) + '(?s).*?' + [regex]::Escape($PROFILE_MARKER_E)
        $content = [regex]::Replace($content, $pattern, $block.TrimEnd())
        Set-Content -Path $PROFILE -Value $content -Encoding UTF8
        Show-Success "Updated existing profile block in $PROFILE"
    } else {
        Add-Content -Path $PROFILE -Value "`n$block`n" -Encoding UTF8
        Show-Success "Added oh-my-psmux block to $PROFILE"
    }
}

function Remove-ProfileBlock {
    if (-not (Test-Path $PROFILE)) { return }
    $content = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if (-not $content -or -not ($content -match [regex]::Escape($PROFILE_MARKER_B))) { return }

    $pattern = [regex]::Escape($PROFILE_MARKER_B) + '(?s).*?' + [regex]::Escape($PROFILE_MARKER_E)
    $content = [regex]::Replace($content, $pattern, '')
    Set-Content -Path $PROFILE -Value $content.TrimEnd() -Encoding UTF8
    Show-Success "Removed oh-my-psmux block from $PROFILE"
}

# ======================================================================
# 6. oh-my-psmux.ps1 download
# ======================================================================

function Install-OhMyPsmuxScript {
    Show-Step 'Installing oh-my-psmux.ps1'

    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    # If a local copy sits next to this installer, prefer it
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $localCopy = Join-Path $here 'oh-my-psmux.ps1'

    $dest = Join-Path $InstallDir 'oh-my-psmux.ps1'

    if (Test-Path $localCopy) {
        Show-Muted "Using local copy: $localCopy"
        Copy-Item $localCopy $dest -Force
    } else {
        Run-Spinner 'Downloading oh-my-psmux.ps1...' {
            Invoke-WebRequest -Uri $OH_MY_PSMUX_URL -OutFile $dest -UseBasicParsing
        } | Out-Null
    }

    if (Test-Path $dest) {
        Show-Success "Installed to $dest"
        return $dest
    } else {
        Show-Error 'Could not install oh-my-psmux.ps1'
        return $null
    }
}

# ======================================================================
# 7. Theme + plugin setup
# ======================================================================

function Set-UpThemeAndPlugins {
    param([string] $OhMyPsmuxPath)

    if (-not $OhMyPsmuxPath -or -not (Test-Path $OhMyPsmuxPath)) { return }

    Show-Step 'Theme and plugins'

    if (Confirm-Action 'Write the oh-my-psmux theme to ~/.psmux.conf?' -DefaultYes) {
        try {
            . $OhMyPsmuxPath 2>$null | Out-Null
            Set-OhMyPsmuxTheme 2>$null | Out-Null
            Show-Success 'Theme written to ~/.psmux.conf'
        } catch {
            Show-Warn "Theme setup skipped: $_"
        }
    }

    if (Confirm-Action 'Declare the curated plugin set (ppm, sensible, pain-control, resurrect, continuum, battery)?' -DefaultYes) {
        try {
            Install-OhMyPsmuxPlugins 2>$null | Out-Null
            Show-Success 'Plugin declarations written'
            Show-Muted '  Press Prefix + I inside a psmux session to install them.'
        } catch {
            Show-Warn "Plugin setup skipped: $_"
        }
    }
}

# ======================================================================
# 8. Uninstall path
# ======================================================================

function Invoke-Uninstall {
    Show-Step 'Uninstalling oh-my-psmux'

    Remove-ProfileBlock

    $scriptPath = Join-Path $InstallDir 'oh-my-psmux.ps1'
    if (Test-Path $scriptPath) {
        if (Confirm-Action "Delete $scriptPath?" -DefaultYes) {
            Remove-Item $scriptPath -Force
            Show-Success 'Removed oh-my-psmux.ps1'
        }
    }

    $cfg = "$HOME\.psmux.conf"
    if (Test-Path $cfg) {
        $content = Get-Content $cfg -Raw
        $b = '# >>> oh-my-psmux theme >>>'
        $e = '# <<< oh-my-psmux theme <<<'
        if ($content -match [regex]::Escape($b)) {
            if (Confirm-Action 'Strip the oh-my-psmux theme block from ~/.psmux.conf?' -DefaultYes) {
                $pattern = [regex]::Escape($b) + '(?s).*?' + [regex]::Escape($e)
                $content = [regex]::Replace($content, $pattern, '')
                $b2 = '# >>> oh-my-psmux plugins >>>'
                $e2 = '# <<< oh-my-psmux plugins <<<'
                $pattern2 = [regex]::Escape($b2) + '(?s).*?' + [regex]::Escape($e2)
                $content = [regex]::Replace($content, $pattern2, '')
                Set-Content $cfg $content.TrimEnd() -Encoding UTF8
                Show-Success 'Stripped oh-my-psmux blocks from ~/.psmux.conf'
            }
        }
    }

    if (Confirm-Action 'Also uninstall psmux itself?' ) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Run-Spinner 'Uninstalling psmux via winget...' { winget uninstall psmux 2>$null | Out-Null } | Out-Null
        }
    }

    Show-Success 'Uninstall complete. Restart your shell.'
}

# ======================================================================
# 9. Main flow
# ======================================================================

function Invoke-Main {
    Show-Banner

    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

    # --- Prerequisites -------------------------------------------------
    if (-not (Test-Prerequisites)) {
        Show-Error 'Prerequisites not met. Aborting.'
        exit 1
    }

    # --- Mode ----------------------------------------------------------
    Show-Step 'Installation scope'
    $mode = Ask-Choose -Prompt 'What would you like to install?' -Options @(
        'Full setup (psmux + oh-my-psmux + theme + plugins)',
        'oh-my-psmux only (psmux already installed)',
        'psmux only (no profile changes)',
        'Custom…'
    )

    $doPsmux  = $false
    $doScript = $false
    $doTheme  = $false

    switch -Regex ($mode) {
        '^Full'    { $doPsmux = $true;  $doScript = $true; $doTheme = $true }
        '^oh-my'   { $doPsmux = $false; $doScript = $true; $doTheme = $true }
        '^psmux'   { $doPsmux = $true;  $doScript = $false; $doTheme = $false }
        '^Custom'  {
            $doPsmux  = Confirm-Action 'Install psmux?' -DefaultYes
            $doScript = Confirm-Action 'Install oh-my-psmux.ps1 and wire up your profile?' -DefaultYes
            $doTheme  = $doScript -and (Confirm-Action 'Write theme + plugin config to ~/.psmux.conf?' -DefaultYes)
        }
    }

    # --- Install directory --------------------------------------------
    if ($doScript) {
        Show-Step 'Install location'
        $chosen = Ask-Input -Prompt 'Where should oh-my-psmux.ps1 live?' `
            -Placeholder "$HOME\Documents\PowerShell\Scripts" `
            -Default $InstallDir
        if ($chosen) { $InstallDir = $chosen }
        Show-Muted "  → $InstallDir"
    }

    # --- Confirmation summary -----------------------------------------
    Write-Host ''
    gum style --border rounded --border-foreground $C.Secondary --padding "1 3" --margin "1 2" `
        "$(gum style --foreground $C.Accent --bold 'Ready to install')
$(if($doPsmux){'  • psmux via package manager'}else{'  • psmux: skip'})
$(if($doScript){'  • oh-my-psmux.ps1 → ' + $InstallDir}else{'  • oh-my-psmux.ps1: skip'})
$(if($doTheme){'  • theme + plugins → ~/.psmux.conf'}else{'  • theme + plugins: skip'})"

    if (-not (Confirm-Action 'Proceed with installation?' -DefaultYes)) {
        Show-Warn 'Cancelled by user.'
        return
    }

    # --- Execute -------------------------------------------------------
    if ($doPsmux)  { Install-Psmux }

    $installed = $null
    if ($doScript) {
        $installed = Install-OhMyPsmuxScript
        if ($installed) { Write-ProfileBlock -ScriptPath $installed }
    }

    if ($doTheme -and $installed) {
        Set-UpThemeAndPlugins -OhMyPsmuxPath $installed
    }

    # --- Optional Windows Terminal tweak -------------------------------
    if ($doScript -and (Get-Command wt -ErrorAction SilentlyContinue)) {
        Show-Step 'Windows Terminal'
        if (Confirm-Action 'Set PowerShell 7 as the default Windows Terminal profile?' ) {
            Show-Muted '  (You can always change this from Settings → Startup)'
            Show-Info  'Windows Terminal default profile is managed via settings.json.'
            Show-Muted '  Open:  wt settings'
        }
    }

    # --- Done ----------------------------------------------------------
    Write-Host ''
    gum style --border double --border-foreground $C.Success --padding "1 4" --margin "1 2" --align center `
        "$(gum style --foreground $C.Success --bold 'Installation complete!')

$(gum style --foreground $C.Text 'Next steps:')

$(gum style --foreground $C.Accent '  1.') Restart your PowerShell session
$(gum style --foreground $C.Accent '  2.') Run  $(gum style --foreground $C.Primary --bold 'pstheme')  to apply the theme
$(gum style --foreground $C.Accent '  3.') Run  $(gum style --foreground $C.Primary --bold 'psn dev')  to create a session
$(gum style --foreground $C.Accent '  4.') Run  $(gum style --foreground $C.Primary --bold 'pscheat')  for key bindings

$(gum style --foreground $C.Muted 'Docs: https://github.com/psmux/psmux')"

    if (Confirm-Action 'Open a fresh PowerShell window now?' -DefaultYes) {
        Start-Process pwsh -ArgumentList '-NoExit','-Command',"& '$PROFILE'"
    }
}

# ======================================================================
# 10. Entry point
# ======================================================================

try {
    Invoke-Main
} catch {
    Write-Host ''
    Show-Error "Installer crashed: $_"
    Show-Muted $_.ScriptStackTrace
    exit 1
}