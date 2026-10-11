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
    [switch]$NoPauseOnSuccess,
    [switch]$NoPauseOnError,
    [string]$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe",
    [string]$CommandShellExe = "$env:SystemRoot\System32\cmd.exe"
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

function Add-CmdPause {
    param(
        [System.Collections.Generic.List[string]]$Commands,
        [string]$Condition
    )

    if ([string]::IsNullOrWhiteSpace($Condition)) {
        return
    }

    $Commands.Add('echo.')
    $Commands.Add('echo Docker WSL Kickstart finished with exit code %EXITCODE%.')
    $Commands.Add("if $Condition pause")
}

function Enable-ShortcutRunAsAdministrator {
    param([string]$ShortcutPath)

    $bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
    $linkFlagsOffset = 0x15
    $runAsUserFlag = 0x20

    if ($bytes.Length -le $linkFlagsOffset) {
        throw "Shortcut '$ShortcutPath' is not a valid Windows shortcut."
    }

    $bytes[$linkFlagsOffset] = [byte]($bytes[$linkFlagsOffset] -bor $runAsUserFlag)
    [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
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

if (-not (Test-Path -LiteralPath $CommandShellExe -PathType Leaf)) {
    throw "Command shell executable was not found at '$CommandShellExe'."
}

if (-not $ShortcutName.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) {
    $ShortcutName = "$ShortcutName.lnk"
}

$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add('-NoProfile')
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

if ($PSBoundParameters.ContainsKey('VhdxSearchRoots')) {
    foreach ($root in $VhdxSearchRoots) {
        Add-NamedArgument -Arguments $arguments -Name '-VhdxSearchRoots' -Value $root
    }
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

$desktop = [Environment]::GetFolderPath('DesktopDirectory')
if ([string]::IsNullOrWhiteSpace($desktop)) {
    throw 'Unable to locate the current user desktop folder.'
}

$shortcutPath = Join-Path $desktop $ShortcutName
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $CommandShellExe

$commands = [System.Collections.Generic.List[string]]::new()
$commands.Add((Quote-Argument $PowerShellExe) + ' ' + ($arguments -join ' '))
$commands.Add('set "EXITCODE=%ERRORLEVEL%"')
if (-not $NoPauseOnSuccess -and -not $NoPauseOnError) {
    Add-CmdPause -Commands $commands -Condition '1 EQU 1'
} elseif (-not $NoPauseOnSuccess) {
    Add-CmdPause -Commands $commands -Condition '%EXITCODE% EQU 0'
} elseif (-not $NoPauseOnError) {
    Add-CmdPause -Commands $commands -Condition '%EXITCODE% NEQ 0'
}
$commands.Add('exit /b %EXITCODE%')

$shortcut.Arguments = '/d /s /c "' + ($commands -join ' & ') + '"'
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.Description = 'Restore Docker Desktop and WSL after reboot.'

if (-not [string]::IsNullOrWhiteSpace($DockerDesktopPath) -and (Test-Path -LiteralPath $DockerDesktopPath -PathType Leaf)) {
    $shortcut.IconLocation = $DockerDesktopPath
} else {
    $shortcut.IconLocation = "$PowerShellExe,0"
}

$shortcut.Save()
Enable-ShortcutRunAsAdministrator -ShortcutPath $shortcutPath

Write-Host "Created desktop shortcut: $shortcutPath"
Write-Host 'The shortcut is configured to run as administrator.'
