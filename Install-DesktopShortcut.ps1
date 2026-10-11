[CmdletBinding()]
param(
    [string]$InstallDirectory = $PSScriptRoot,
    [string]$ShortcutName = 'Restore Docker Desktop and WSL.lnk',
    [string]$DockerDesktopPath,
    [string]$CodePath,
    [string[]]$WslDistros = @(),
    [string[]]$VhdxSearchRoots = @('C:\', 'D:\'),
    [int]$TimeoutSeconds = 120,
    [switch]$RestartWsl,
    [switch]$SkipVsCodeSave,
    [switch]$SkipUpdate,
    [switch]$RecoverDockerDesktopDistro,
    [switch]$NoPauseOnError,
    [string]$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Quote-Argument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    return '"' + ($Value -replace '"', '\"') + '"'
}

function Add-NamedArgument {
    param(
        [System.Collections.Generic.List[string]]$Arguments,
        [string]$Name,
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $Arguments.Add($Name)
        $Arguments.Add((Quote-Argument $Value))
    }
}

if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
    throw "InstallDirectory '$InstallDirectory' does not exist."
}

$kickstartScript = Join-Path $InstallDirectory 'DockerWslKickstart.ps1'
if (-not (Test-Path -LiteralPath $kickstartScript -PathType Leaf)) {
    throw "Kickstart script was not found at '$kickstartScript'."
}

if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    throw "PowerShell executable was not found at '$PowerShellExe'."
}

if (-not $ShortcutName.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
    $ShortcutName = "$ShortcutName.lnk"
}

$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add('-NoProfile')
$arguments.Add('-NoExit')
$arguments.Add('-ExecutionPolicy')
$arguments.Add('Bypass')
$arguments.Add('-File')
$arguments.Add((Quote-Argument $kickstartScript))
$arguments.Add('-TimeoutSeconds')
$arguments.Add($TimeoutSeconds.ToString())

Add-NamedArgument -Arguments $arguments -Name '-DockerDesktopPath' -Value $DockerDesktopPath
Add-NamedArgument -Arguments $arguments -Name '-CodePath' -Value $CodePath

foreach ($distro in $WslDistros) {
    Add-NamedArgument -Arguments $arguments -Name '-WslDistros' -Value $distro
}

foreach ($root in $VhdxSearchRoots) {
    Add-NamedArgument -Arguments $arguments -Name '-VhdxSearchRoots' -Value $root
}

if ($RestartWsl) {
    $arguments.Add('-RestartWsl')
}

if ($SkipVsCodeSave) {
    $arguments.Add('-SkipVsCodeSave')
}

if ($SkipUpdate) {
    $arguments.Add('-SkipUpdate')
}

if ($RecoverDockerDesktopDistro) {
    $arguments.Add('-RecoverDockerDesktopDistro')
}

if (-not $NoPauseOnError) {
    $arguments.Add('-PauseOnError')
}

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw 'Unable to locate the current user desktop folder.'
}

$shortcutPath = Join-Path $desktop $ShortcutName
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $PowerShellExe
$shortcut.Arguments = ($arguments -join ' ')
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.Description = 'Restore Docker Desktop and WSL after reboot.'

if (-not [string]::IsNullOrWhiteSpace($DockerDesktopPath) -and (Test-Path -LiteralPath $DockerDesktopPath -PathType Leaf)) {
    $shortcut.IconLocation = $DockerDesktopPath
} else {
    $shortcut.IconLocation = "$PowerShellExe,0"
}

$shortcut.Save()

Write-Host "Created desktop shortcut: $shortcutPath"
