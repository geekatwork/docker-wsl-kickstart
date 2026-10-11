[CmdletBinding()]
param(
    [string]$DockerDesktopPath,
    [string]$CodePath,
    [string[]]$WslDistros = @(),
    [string[]]$VhdxSearchRoots = @('C:\', 'D:\'),
    [string]$LogFile = "$env:USERPROFILE\docker_update_log.txt",
    [int]$TimeoutSeconds = 120,
    [switch]$RestartWsl,
    [switch]$SkipVsCodeSave,
    [switch]$SkipUpdate,
    [switch]$RecoverDockerDesktopDistro,
    [switch]$PauseOnSuccess,
    [switch]$PauseOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

"=== Docker Desktop Safe Update Started: $(Get-Date) ===" | Out-File -FilePath $LogFile

function Log {
    param([string]$Message)

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$timestamp - $Message" | Tee-Object -FilePath $LogFile -Append
}

function Test-ExecutableFile {
    param([string]$Path)

    $normalizedPath = Normalize-PathText -Path $Path
    return -not [string]::IsNullOrWhiteSpace($normalizedPath) -and (Test-Path -LiteralPath $normalizedPath -PathType Leaf)
}

function Get-EnvironmentPath {
    param([string]$Name)

    return [Environment]::GetEnvironmentVariable($Name)
}

function Join-OptionalPath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    $normalizedBasePath = Normalize-PathText -Path $BasePath
    if ([string]::IsNullOrWhiteSpace($normalizedBasePath)) {
        return $null
    }

    return Join-Path $normalizedBasePath $ChildPath
}

function Normalize-PathText {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return $Path.Trim().Trim('"')
}

function Get-ObjectPropertyValue {
    param(
        [object]$InputObject,
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-DockerDesktopPathFromRegistry {
    $registryRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $registryRoots) {
        $dockerEntry = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { (Get-ObjectPropertyValue -InputObject $_ -PropertyName 'DisplayName') -eq 'Docker Desktop' } |
            Select-Object -First 1

        $installLocation = Normalize-PathText -Path (Get-ObjectPropertyValue -InputObject $dockerEntry -PropertyName 'InstallLocation')
        if ([string]::IsNullOrWhiteSpace($installLocation)) {
            continue
        }

        $candidate = Join-Path $installLocation 'Docker Desktop.exe'
        if (Test-ExecutableFile $candidate) {
            return $candidate
        }
    }

    return $null
}

function Resolve-DockerDesktopPath {
    param([string]$RequestedPath)

    $normalizedRequestedPath = Normalize-PathText -Path $RequestedPath
    if (Test-ExecutableFile $normalizedRequestedPath) {
        return (Resolve-Path -LiteralPath $normalizedRequestedPath).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedRequestedPath)) {
        throw "Docker Desktop was not found at '$normalizedRequestedPath'. Recreate the shortcut with the correct -DockerDesktopPath value."
    }

    $programFiles = Get-EnvironmentPath 'ProgramFiles'
    $programFilesX86 = Get-EnvironmentPath 'ProgramFiles(x86)'
    $localAppData = Get-EnvironmentPath 'LOCALAPPDATA'

    $candidates = @(
        (Join-OptionalPath $programFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-OptionalPath $programFilesX86 'Docker\Docker\Docker Desktop.exe'),
        (Join-OptionalPath $localAppData 'Docker\Docker\Docker Desktop.exe'),
        (Get-DockerDesktopPathFromRegistry)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-ExecutableFile $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Docker Desktop could not be found. Run Install-DesktopShortcut.ps1 with -DockerDesktopPath pointing to Docker Desktop.exe."
}

function Resolve-CodePath {
    param([string]$RequestedPath)

    $normalizedRequestedPath = Normalize-PathText -Path $RequestedPath
    if (Test-ExecutableFile $normalizedRequestedPath) {
        return (Resolve-Path -LiteralPath $normalizedRequestedPath).Path
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedRequestedPath)) {
        throw "VS Code was not found at '$normalizedRequestedPath'. Recreate the shortcut with the correct -CodePath value."
    }

    $candidates = @(
        (Join-OptionalPath (Get-EnvironmentPath 'LOCALAPPDATA') 'Programs\Microsoft VS Code\Code.exe'),
        (Join-OptionalPath (Get-EnvironmentPath 'ProgramFiles') 'Microsoft VS Code\Code.exe'),
        (Join-OptionalPath (Get-EnvironmentPath 'ProgramFiles(x86)') 'Microsoft VS Code\Code.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-ExecutableFile $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Resolve-DockerCliPath {
    param([string]$ResolvedDockerDesktopPath)

    $dockerCommand = Get-Command 'docker.exe' -ErrorAction SilentlyContinue
    if ($null -ne $dockerCommand -and (Test-ExecutableFile $dockerCommand.Source)) {
        return $dockerCommand.Source
    }

    $dockerDirectory = Split-Path -Parent $ResolvedDockerDesktopPath
    $candidate = Join-Path $dockerDirectory 'resources\bin\docker.exe'
    if (Test-ExecutableFile $candidate) {
        return $candidate
    }

    throw "docker.exe was not found on PATH or under Docker Desktop's resources\bin folder."
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        throw "$FilePath $($Arguments -join ' ') failed with exit code $exitCode."
    }

    return $exitCode
}

function Stop-ProcessByImageName {
    param([string]$ImageName)

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ImageName)
    $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
    if ($null -eq $processes) {
        Log "No running $ImageName processes found."
        return
    }

    foreach ($process in $processes) {
        Invoke-NativeCommand -FilePath 'taskkill.exe' -Arguments @('/f', '/pid', $process.Id.ToString()) -IgnoreExitCode | Out-Null
        Log "Killed process: $($process.ProcessName) (PID $($process.Id))"
    }
}

function Close-ProcessByImageName {
    param(
        [string]$ImageName,
        [int]$GraceSeconds = 5
    )

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ImageName)
    $processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Log "No running $ImageName processes found."
        return
    }

    foreach ($process in $processes) {
        if ($process.MainWindowHandle -ne 0) {
            if ($process.CloseMainWindow()) {
                Log "Requested graceful close for $($process.ProcessName) (PID $($process.Id))."
            }
        }
    }

    Start-Sleep -Seconds $GraceSeconds
    Stop-ProcessByImageName -ImageName $ImageName
}

function Save-CodeBeforeClose {
    param([string]$ResolvedCodePath)

    $codeProcesses = @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
    if ($codeProcesses.Count -eq 0) {
        Log 'VS Code is not running; no save request needed.'
        return
    }

    if ([string]::IsNullOrWhiteSpace($ResolvedCodePath)) {
        Log 'VS Code executable was not found. Unable to send Save All before closing.'
        return
    }

    Log 'Requesting VS Code Save All before closing...'
    Start-Process -FilePath $ResolvedCodePath -ArgumentList @('--reuse-window', '--command', 'workbench.action.files.saveAll')
    Start-Sleep -Seconds 5
    Log 'VS Code Save All command was sent.'
}

function Find-DockerVhdx {
    param([string[]]$SearchRoots)

    Log 'Searching for Docker VHDX...'

    $existingRoots = @($SearchRoots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($existingRoots.Count -eq 0) {
        Log 'No configured VHDX search roots exist. Continuing anyway.'
        return $null
    }

    $dockerVhdx = Get-ChildItem -Path $existingRoots -Recurse -Filter 'ext4.vhdx' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'docker' -or $_.FullName -match 'wsl' } |
        Select-Object -First 1

    if ($dockerVhdx) {
        Log "Detected VHDX: $($dockerVhdx.FullName)"
    } else {
        Log 'No Docker VHDX found. Continuing anyway.'
    }

    return $dockerVhdx
}

function Test-VhdxLock {
    param($DockerVhdx)

    if ($null -eq $DockerVhdx) {
        return
    }

    Log 'Checking VHDX lock state...'
    try {
        $stream = [System.IO.File]::Open($DockerVhdx.FullName, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        Log 'VHDX is not locked.'
    } catch {
        Log 'VHDX appears locked. This may cause update issues.'
    }
}

function Get-LatestDockerDesktopVersion {
    Log 'Fetching latest Docker Desktop version info...'
    $latestInfo = Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/appcast.xml' -UseBasicParsing
    $latestVersion = ([regex]::Match($latestInfo.Content, '<sparkle:shortVersionString>(.*?)</sparkle:shortVersionString>').Groups[1].Value)
    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        throw 'Unable to parse the latest Docker Desktop version from appcast.xml.'
    }

    Log "Latest available version: $latestVersion"
    return $latestVersion
}

function Update-DockerDesktopIfNeeded {
    param([string]$ResolvedDockerDesktopPath)

    if ($SkipUpdate) {
        Log 'Skipping Docker Desktop update check because -SkipUpdate was supplied.'
        return
    }

    Log 'Checking current Docker Desktop version...'
    $installedVersion = (Get-Item -LiteralPath $ResolvedDockerDesktopPath).VersionInfo.ProductVersion
    Log "Installed version: $installedVersion"

    $latestVersion = Get-LatestDockerDesktopVersion
    if ($installedVersion -eq $latestVersion) {
        Log 'Docker Desktop is already up to date. No update required.'
        return
    }

    Log 'Downloading latest Docker Desktop installer...'
    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Invoke-WebRequest -Uri 'https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe' -OutFile $installer -UseBasicParsing
    Log "Docker Desktop installer downloaded to $installer."

    Log 'Running Docker Desktop installer...'
    Start-Process -FilePath $installer -ArgumentList '--install' -Wait
    Log 'Docker Desktop installation completed.'
}

function Stop-DockerAndWsl {
    param([string]$ResolvedCodePath)

    if ($SkipVsCodeSave) {
        Log 'Skipping VS Code Save All because -SkipVsCodeSave was supplied.'
    } else {
        Save-CodeBeforeClose -ResolvedCodePath $ResolvedCodePath
    }

    Log 'Closing VS Code...'
    Close-ProcessByImageName -ImageName 'Code.exe'
    Log 'VS Code closed.'

    Log 'Stopping Docker Desktop...'
    Stop-ProcessByImageName -ImageName 'Docker Desktop.exe'
    Stop-ProcessByImageName -ImageName 'com.docker.backend.exe'
    Stop-ProcessByImageName -ImageName 'com.docker.service.exe'
    Log 'Docker Desktop processes terminated.'

    Log 'Shutting down WSL...'
    Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--shutdown') -IgnoreExitCode | Out-Null
    Start-Sleep -Seconds 2
    Log 'WSL shutdown requested.'

    Log 'Checking for lingering WSL processes...'
    $wslProcs = Get-Process '*wsl*' -ErrorAction SilentlyContinue
    if ($wslProcs) {
        Log 'Lingering WSL processes detected. Terminating...'
        foreach ($process in $wslProcs) {
            Invoke-NativeCommand -FilePath 'taskkill.exe' -Arguments @('/f', '/pid', $process.Id.ToString()) -IgnoreExitCode | Out-Null
            Log "Killed process: $($process.ProcessName) (PID $($process.Id))"
        }
    } else {
        Log 'No lingering WSL processes found.'
    }

    Log 'Stopping Windows 11 WSL service...'
    Invoke-NativeCommand -FilePath 'net.exe' -Arguments @('stop', 'WslService') -IgnoreExitCode | Out-Null
    Log 'WSL service stop requested.'
}

function Start-DockerDesktop {
    param([string]$ResolvedDockerDesktopPath)

    Log 'Starting Docker Desktop...'
    Start-Process -FilePath $ResolvedDockerDesktopPath -WorkingDirectory (Split-Path -Parent $ResolvedDockerDesktopPath)
    Log "Docker Desktop started from '$ResolvedDockerDesktopPath'."
}

function Wait-ForDockerEngine {
    param(
        [string]$DockerCliPath,
        [int]$Timeout
    )

    Log "Waiting up to $Timeout seconds for Docker engine to initialize..."
    $deadline = (Get-Date).AddSeconds($Timeout)

    do {
        $exitCode = Invoke-NativeCommand -FilePath $DockerCliPath -Arguments @('info') -IgnoreExitCode
        if ($exitCode -eq 0) {
            Log 'Docker engine is running normally.'
            return $true
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    Log "Docker engine failed to start within $Timeout seconds."
    return $false
}

function Start-WslDistros {
    param([string[]]$RequestedDistros)

    $distrosToStart = @($RequestedDistros | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($distrosToStart.Count -eq 0) {
        $rawOutput = & wsl.exe --list --quiet
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to list WSL distros with wsl.exe --list --quiet.'
        }

        $distrosToStart = @(
            $rawOutput |
                ForEach-Object { ($_ -replace "`0", '').Trim() } |
                Where-Object { $_ -and $_ -notlike 'docker-desktop*' }
        )
    }

    if ($distrosToStart.Count -eq 0) {
        Log 'No non-Docker WSL distros were found to start.'
        return
    }

    foreach ($distro in $distrosToStart) {
        Log "Starting WSL distro '$distro'."
        Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('-d', $distro, '--exec', 'sh', '-lc', 'true') | Out-Null
    }
}

function Restart-Code {
    param([string]$ResolvedCodePath)

    if ([string]::IsNullOrWhiteSpace($ResolvedCodePath)) {
        Log 'VS Code executable was not found. Skipping VS Code restart.'
        return
    }

    Log 'Final restart of VS Code...'
    Close-ProcessByImageName -ImageName 'Code.exe'
    Start-Sleep -Seconds 2
    Start-Process -FilePath $ResolvedCodePath
    Log "VS Code restarted from '$ResolvedCodePath'."
}

try {
    $dockerVhdx = Find-DockerVhdx -SearchRoots $VhdxSearchRoots
    $resolvedDockerDesktopPath = Resolve-DockerDesktopPath -RequestedPath $DockerDesktopPath
    $resolvedCodePath = Resolve-CodePath -RequestedPath $CodePath

    if ($RestartWsl) {
        Stop-DockerAndWsl -ResolvedCodePath $resolvedCodePath
        Test-VhdxLock -DockerVhdx $dockerVhdx
    }

    Update-DockerDesktopIfNeeded -ResolvedDockerDesktopPath $resolvedDockerDesktopPath

    $dockerCliPath = Resolve-DockerCliPath -ResolvedDockerDesktopPath $resolvedDockerDesktopPath
    Start-DockerDesktop -ResolvedDockerDesktopPath $resolvedDockerDesktopPath

    if (-not (Wait-ForDockerEngine -DockerCliPath $dockerCliPath -Timeout $TimeoutSeconds)) {
        if (-not $RecoverDockerDesktopDistro) {
            throw 'Docker engine failed to start. Re-run with -RecoverDockerDesktopDistro to unregister and recreate Docker Desktop internal WSL state.'
        }

        Log 'Docker engine failed to start. Attempting automatic recovery...'
        Log 'Unregistering corrupted docker-desktop distro...'
        Invoke-NativeCommand -FilePath 'wsl.exe' -Arguments @('--unregister', 'docker-desktop') | Out-Null
        Log 'Restarting Docker Desktop...'
        Start-DockerDesktop -ResolvedDockerDesktopPath $resolvedDockerDesktopPath
        if (-not (Wait-ForDockerEngine -DockerCliPath $dockerCliPath -Timeout $TimeoutSeconds)) {
            throw 'Docker engine still failed to start after docker-desktop distro recovery.'
        }
    }

    Start-WslDistros -RequestedDistros $WslDistros

    Log 'Final restart of Docker Desktop...'
    Stop-ProcessByImageName -ImageName 'Docker Desktop.exe'
    Start-Sleep -Seconds 2
    Start-DockerDesktop -ResolvedDockerDesktopPath $resolvedDockerDesktopPath
    Wait-ForDockerEngine -DockerCliPath $dockerCliPath -Timeout $TimeoutSeconds | Out-Null
    Log 'Docker Desktop restarted successfully.'

    Restart-Code -ResolvedCodePath $resolvedCodePath

    Log '=== Safe Update Script Completed (Final Restart Done) ==='
    Write-Host "`nDocker Desktop and VS Code restarted. Log saved to $LogFile"
    if ($PauseOnSuccess) {
        Write-Host ""
        Read-Host 'Press Enter to close this window'
    }
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    if ($_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
        Log "ERROR LOCATION: $($_.InvocationInfo.PositionMessage)"
    }
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        Log "ERROR STACK: $($_.ScriptStackTrace)"
    }
    Write-Error $_
    if ($PauseOnError) {
        Write-Host ""
        Write-Host "An error occurred. Review the message above or the log file:"
        Write-Host $LogFile
        Read-Host 'Press Enter to close this window'
    }
    exit 1
}
