# Docker WSL Kickstart

Creates a Windows desktop shortcut that runs a Docker Desktop safe update and
restore flow after a reboot. It supports Docker Desktop installed in the default
location or in a custom location.

## Background

Docker Desktop on Windows relies on WSL 2, Docker's own internal WSL distros,
the Docker backend process, and one or more WSL `ext4.vhdx` disk files. After a
Windows reboot, sleep/hibernate cycle, failed update, or forced shutdown, those
pieces can sometimes come back in the wrong order or stay locked by another
process.

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

The script is intentionally configurable because Docker Desktop and VS Code are
not always installed in their default locations.

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

## Docker Desktop in a custom location

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

## Restore only, without checking for updates

To skip the Docker Desktop version check and installer download:

```powershell
.\Install-DesktopShortcut.ps1 -SkipUpdate
```

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

## Troubleshooting

- If the shortcut cannot find Docker Desktop, recreate it with
  `-DockerDesktopPath`.
- If VS Code is installed somewhere custom and does not restart at the end,
  recreate the shortcut with `-CodePath`.
- If Docker often fails because VS Code is open, create the shortcut with
  `-RestartWsl` so VS Code is closed before WSL and Docker are stopped.
- If VS Code does not save before closing, recreate the shortcut with
  `-CodePath` so the script can send VS Code's `workbench.action.files.saveAll`
  command to the right executable.
- If WSL is not installed or no distros are registered, the script still starts
  Docker Desktop and reports the WSL issue.
- If Docker takes longer than two minutes to start, recreate the shortcut with a
  larger timeout:

  ```powershell
  .\Install-DesktopShortcut.ps1 -TimeoutSeconds 240
  ```
