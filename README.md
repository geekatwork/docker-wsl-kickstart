# Docker WSL Kickstart

Creates a Windows desktop shortcut that runs a Docker Desktop safe update and
restore flow after a reboot. It supports Docker Desktop installed in the default
location, including setups where Docker Desktop's disk image is stored in a
custom location.

This is mainly intended to fix Docker Desktop restart failures after updates or
reboots, especially on systems where Docker Desktop's volume/disk image location
is non-standard.

## Background

Docker Desktop on Windows relies on WSL 2, Docker's own internal WSL distros,
the Docker backend process, and one or more WSL `ext4.vhdx` disk files. After a
Windows reboot, sleep/hibernate cycle, failed update, or forced shutdown, those
pieces can sometimes come back in the wrong order or stay locked by another
process.

The problem is more noticeable when Docker Desktop stores its WSL data or volume
disk image outside the default location. Docker Desktop still knows where that
disk image lives, but updates and restarts can be more sensitive to lingering
locks from WSL, Docker backend processes, terminals, or VS Code.

The common result is that Docker Desktop opens but the engine never becomes
usable. Typical symptoms include:

- Docker Desktop is stuck on **Starting**.
- `docker info` hangs or fails.
- WSL distros start, but Docker commands do not work.
- Docker starts only after manually running `wsl --shutdown`.
- Docker Desktop updates fail because a WSL VHDX file is still locked.
- Docker Desktop works again only after killing `com.docker.backend.exe` or
  restarting WSL.

VS Code is a frequent cause of the lock. When VS Code is connected to WSL,
Dev Containers, or a workspace using Docker, it can keep WSL processes, mounted
filesystems, terminals, language servers, or container-related handles alive.
That can prevent Docker Desktop and WSL from fully stopping during an update or
restart.

This project packages the manual recovery sequence into a repeatable shortcut:
ask VS Code to save all open editors, close VS Code, stop Docker Desktop, shut
down WSL, check for locked Docker/WSL disk files, update or restart Docker
Desktop, wait for the Docker engine, start the chosen WSL distros, and then
restart VS Code.

The script does not need to know Docker Desktop's disk image location. Docker
Desktop already tracks that setting. The script only starts/stops Docker and WSL
through their normal commands, with an optional best-effort VHDX lock check.

## Files

- `DockerWslKickstart.ps1` - logs the run, detects Docker/WSL VHDX files, checks
  for Docker Desktop updates, restarts Docker Desktop, waits for the Docker
  engine, starts WSL distros, and restarts VS Code when it can be found.
- `Install-DesktopShortcut.ps1` - creates the desktop shortcut.

## Quick start

Open PowerShell in this folder and run:

```powershell
.\Install-DesktopShortcut.ps1
```

Then double-click **Restore Docker Desktop and WSL** on your desktop after a
reboot.

The generated shortcut is configured to run as administrator, so Windows will
show a UAC prompt when you launch it. Elevation allows the script to stop the
WSL service and clear locks that a non-admin process may not be able to release.

The shortcut runs `DockerWslKickstart.ps1` from the folder where you checked out
or copied this project. Keep the project folder in that location. If you move or
rename the folder later, run `Install-DesktopShortcut.ps1` again from the new
location to recreate the shortcut.

Shortcut-created runs pause after PowerShell exits so you can read the message
even if the script ends with an error. They also pause after a successful run
and show a clear
**Docker WSL Kickstart completed successfully** banner with the log path. The
same output is also written to:

```text
%USERPROFILE%\docker_update_log.txt
```

VS Code is restarted by asking Windows Explorer to open it, so it is detached
from the shortcut's command window. After the success banner appears, closing
the command window should not close the restarted VS Code instance.

## Docker Desktop in a custom install location

If Docker Desktop is not installed in a standard location, pass the full path to
`Docker Desktop.exe` when creating the shortcut:

```powershell
.\Install-DesktopShortcut.ps1 `
  -DockerDesktopPath "D:\Apps\Docker\Docker Desktop.exe"
```

The generated shortcut stores that path, so it will keep using the custom Docker
Desktop installation.

## VS Code in a custom location

If VS Code is also installed in a custom location, pass it when creating the
shortcut:

```powershell
.\Install-DesktopShortcut.ps1 `
  -DockerDesktopPath "D:\Apps\Docker\Docker Desktop.exe" `
  -CodePath "D:\Apps\VS Code\Code.exe"
```

## Choose WSL distros to start

By default, the script starts every registered WSL distro except Docker Desktop's
internal distros. To start only specific distros:

```powershell
.\Install-DesktopShortcut.ps1 -WslDistros Ubuntu Debian
```

## Force a clean WSL restart

To shut down Docker Desktop, WSL, and related lingering processes first:

```powershell
.\Install-DesktopShortcut.ps1 -RestartWsl
```

This option asks VS Code to **Save All** before closing it and then closes VS
Code before stopping Docker and WSL. VS Code usually restores windows and
unsaved editors, but saving your work first is still recommended because
external save requests depend on VS Code responding normally. Untitled files
that have never been saved may still require VS Code to prompt for a file name.

To close VS Code without sending the Save All request:

```powershell
.\Install-DesktopShortcut.ps1 -RestartWsl -SkipVsCodeSave
```

To create a shortcut that does not pause after a successful run:

```powershell
.\Install-DesktopShortcut.ps1 -NoPauseOnSuccess
```

## Restore only, without checking for updates

To skip the Docker Desktop version check and installer download:

```powershell
.\Install-DesktopShortcut.ps1 -SkipUpdate
```

This is the recommended mode when you only want to recover Docker Desktop and
WSL after a reboot.

## Recover Docker Desktop internal WSL state

If the Docker engine does not start, you can allow the script to unregister and
recreate Docker Desktop's internal `docker-desktop` WSL distro:

```powershell
.\Install-DesktopShortcut.ps1 -RecoverDockerDesktopDistro
```

Use this only when normal restart recovery fails. It removes Docker Desktop's
internal WSL distro and lets Docker Desktop recreate it.

## Run without a shortcut

You can run the kickstart script directly:

```powershell
.\DockerWslKickstart.ps1 `
  -DockerDesktopPath "D:\Apps\Docker\Docker Desktop.exe" `
  -WslDistros Ubuntu `
  -RestartWsl `
  -SkipUpdate
```

## What the scripts handle

The current scripts include a few details that are easy to get wrong when
building this shortcut by hand:

- The generated shortcut launches through `cmd.exe`, runs PowerShell with the
  intended arguments, and pauses after PowerShell exits so errors stay visible.
- Shortcut arguments are quoted so paths such as `C:\`, custom Docker Desktop
  locations, and custom VS Code locations are passed to PowerShell correctly.
- The shortcut is marked to run as administrator so Windows shows a UAC prompt.
- VS Code is restarted through Windows Explorer so it is detached from the
  shortcut's command window.
- Docker Desktop can use a custom disk image location without any extra
  shortcut argument. Docker Desktop already tracks that setting.
- If the Docker Desktop update feed cannot be parsed, the script logs that and
  skips the update check so the restart/recovery flow can continue.
- While waiting after **Starting Docker Desktop**, the script logs whether it is
  still waiting for Docker Desktop's engine pipe or for the Docker engine to
  answer.
- If WSL is not installed or no distros are registered, the script still starts
  Docker Desktop and reports the WSL issue.
- With `-RestartWsl`, the script asks VS Code to save all open editors before it
  closes VS Code and stops WSL/Docker.

Run `Install-DesktopShortcut.ps1` again after changing the script location,
Docker Desktop path, VS Code path, WSL distro list, or timeout because those
values are stored in the generated shortcut.

If Docker takes longer than two minutes to start, recreate the shortcut with a
larger timeout:

```powershell
.\Install-DesktopShortcut.ps1 -TimeoutSeconds 240
```
