@echo off
REM Runs as SYSTEM after OOBE completes, with no logon required -- proven on
REM real hardware to be the correct headless provisioning hook (see
REM unattend.xml's header comment). Deliberately minimal: just get SSH up and
REM the baked password stable, so build.ps1 can take over everything else
REM (activation, Windows Update, toolchain, launcher) over SSH from the host,
REM the same way runny itself provisions guests at runtime.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service -Name sshd -StartupType Automatic; Start-Service sshd"
powershell -NoProfile -ExecutionPolicy Bypass -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-LocalUser -Name Administrator -PasswordNeverExpires $true"
REM If the factory injected a build-time SSH key (build.ps1 stage 0), give it
REM the restrictive ACL Windows OpenSSH requires for admin-group keys --
REM without exactly this ACL (SYSTEM + Administrators only), sshd silently
REM ignores the file. No-op when the file is absent.
if exist C:\ProgramData\ssh\administrators_authorized_keys (
  icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "SYSTEM:F" /grant "BUILTIN\Administrators:F"
)
echo provisioned> C:\provisioned.txt
