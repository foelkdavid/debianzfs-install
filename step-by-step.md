# Installation walkthrough

1. Download an official [Debian 13 amd64 live image](https://www.debian.org/CD/live/).
   Disable Secure Boot in firmware, then boot it in UEFI mode. BIOS mode is
   displayed, then stops because support is pending. Use live media rather than
   an installer rescue shell.
2. Connect the live environment to the internet (wired or Wi-Fi), then install
   `git`, `ca-certificates` and `curl`. Clone this repository's `v1.0.0` branch.
3. Run `sudo ./install.sh`. Quick local checks lead straight to configuration;
   no package updates or downloads run before you finish the questions. The
   display identifies the detected boot mode and log location. If Secure Boot
   is enabled, reboot and disable it in UEFI firmware before continuing.
4. Answer each question. Select whole disks you intend to **erase**. A mirror
   uses two distinct disks; swap is optional (`0`/`none` disables it). Select
   ZFS encryption (default yes), hostname, account and timezone. The console
   keyboard question does not change Hyprland's German/Bone layout.
5. Choose whether to deploy the desktop (default yes). If enabled, select a
   GPU profile; VM mode also offers guest integration and software rendering.
   Automatic VM detection happens in the live environment. DHCP applies to
   the chosen network manager: NetworkManager for desktop, networkd for clean.
6. Confirm the account password and, if encrypted, the ZFS passphrase. Use a
   passphrase you can type with ZFSBootMenu's US keyboard. Values are hidden
   and never logged. Review the entire summary, especially the ERASE disks.
7. Choose **Start installation**, **Restart configuration**, or **Exit**.
   Restart clears all answers and secrets; Exit leaves packages and disks alone.
   After Start, the installer checks connectivity, updates packages, prepares
   live dependencies and validates ZFS. Disk partitioning follows a fresh
   disk-safety check. There are no further configuration questions.
8. Follow the colored stage heading and up to five lines of current output.
   The previous stage's output clears automatically. Full logs remain in
   `/var/log/debianzfs-install/` in the live system; their path is displayed.
   There is no log VT or TTY switching. Failure stops installation and retains
   the log. `NO_COLOR=1` disables colors if preferred.
9. Wait for the explicit success message after unmounting and pool export.
   Reboot and remove the live medium. Unlock encrypted ZFS in ZFSBootMenu, then
   log in using your configured username and account password.
10. With desktop deployment, log in on TTY1: Hyprland starts after the normal
    login. Exiting returns to your shell. Other TTYs and SSH remain shells.
    Keep `~/.local/deploy`: dotfiles link into it. For later deployment changes,
    run `~/.local/deploy/deploy.sh --dry-run`, then run it as your regular user.
    Saved settings can be overridden with environment variables or edited in
    `~/.local/state/debian-deploy/settings.sh`.

If installation fails, read the failed stage and complete live log before
rebooting. Target logs contain the run through pre-unmount cleanup; only the
live copy includes final export and subsequent failure cleanup. If cleanup
reports remaining mounts/pools or retained policy backups, resolve those using
the logged paths before retrying. Never run the installer on your workstation.
