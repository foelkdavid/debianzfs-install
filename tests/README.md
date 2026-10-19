# Validation

Host-safe functional and pseudo-terminal tests (Python 3 and Bash required):

```sh
python3 tests/test_installer.py
```

The tests source installer functions; disk, mount, ZFS, network and service
operations are mocked. They cover desktop/no-desktop, all GPU profiles,
encryption on/off, secret handling, restart reset, explicit-start gating,
BIOS early stop, HTTPS error propagation, busy/small/duplicate/partition disk
rejection, stage order, networking/DHCP, policy restoration, same-shell state,
nested/pipeline failures, export failures, cleanup retries, mirrored ESP mount
options, full logs and permissions. PTY tests
exercise verbose output, stage transitions, resize, interrupt, cursor restore
and file-only logging without any VT allocation. Startup regression tests cover
configuration before network/package work, restart/exit, Secure Boot detection,
rejected module signatures, compact final review, control-sequence filtering, bounded frames,
renderer shutdown without stale writes, the Void configuration palette,
`NO_COLOR`, Unicode clipping in a C locale and the five-line preview. They never
execute installation on the host.

Syntax/static checks:

```sh
bash -n install.sh
for file in lib/*.sh deploy/*.sh deploy/scripts/*.sh tests/*.sh \
  deploy/dotfiles/fonts/*.sh deploy/dotfiles/zsh/*.sh; do bash -n "$file"; done
shellcheck -x install.sh lib/*.sh deploy/*.sh deploy/scripts/*.sh tests/*.sh \
  deploy/dotfiles/fonts/*.sh deploy/dotfiles/zsh/*.sh
```

Run the following only in **disposable Debian Trixie containers**. They require
root and deliberately refuse other environments. The repository can be mounted
read-only at `/repo`; install their dependencies in the disposable container.

- `bash /repo/tests/container-check.sh`: requires `zsh`, `systemd`, `sudo`,
  `python3`, `xdg-user-dirs`, `procps`. Uses mocked package/download commands
  with real `runuser`, file ownership, Zsh and offline systemctl links. Exercises
  all five chroot profiles, HOME/XDG identity, permanent dotfile links, saved
  settings, package-failure policy restoration, incompatible target NVIDIA
  kernels, missing-ESP sync guards, and TTY1/SSH/nested/graphical/noninteractive guards. Run once in a
  fresh container; it creates a fixture account and mock kernel files.
- `bash /repo/tests/package-plans.sh`: configures the real Debian and Noctalia
  repositories, installs only planning dependencies, and simulates the actual
  requested APT transactions for every GPU profile. Needs network access.
  It does not install desktop packages or validate physical graphics hardware.

For virtual installation tests, use the official Debian 13 standard amd64 live
ISO, UEFI firmware, and new disposable qcow2 disks (40 GiB or larger). Provide a
read-only 9p share of this repository. Boot the live image, mount the share,
copy its contents into a guest directory, and run that immutable copy of
`install.sh` **inside the guest**. Do not edit scripts while a run uses them. Keep guest serial transcripts and
live installer logs. Test at least:

| Scenario | Boot/login/network checks |
| --- | --- |
| Clean, encrypted, one disk | ZFSBootMenu unlock, account login, DHCP, no desktop files |
| Desktop, unencrypted mirror, VM profile | Both ESPs, unlock, NetworkManager, TTY1 starts Hyprland, exit returns to shell |
| Unencrypted ZFS | No key file/hook/passphrase, normal ZFSBootMenu boot |

Do not pass host block devices, writable host `/run`, or developer home
filesystems to the guest. A container may expose `/dev/kvm` for acceleration
while QEMU sees only `/tmp` disk images and read-only ISO/repository mounts.
No host installation or physical-GPU validation is implied by these tests.

## Initial v1.0.0 implementation (033b629, 2026-10-19)

- Bash syntax checks and ShellCheck 0.11.0 passed for installer, libraries,
  deployment and test scripts.
- 19 host-safe functional/PTY tests passed on the development host and Debian
  Trixie. The full container tests passed for all five GPU profiles, including
  real user ownership, Zsh startup guards and real offline systemctl enablement.
- Real APT transaction simulations passed for intel, amd, nvidia, nouveau, vm
  against the configured Debian/Noctalia repositories.
- UEFI QEMU/KVM guest tests used Debian live 13.7.0, target kernel
  6.12.113+deb13-amd64 and ZFS 2.3.9. Clean encrypted single-disk installation
  reached pool export, booted the installed ZFSBootMenu, accepted its passphrase,
  and passed account login, DHCP/DNS and networkd checks. No deployment directory
  was installed.
- An unencrypted two-disk desktop mirror with 1 GiB swap per member completed
  with exit status 0 and successful export. It booted with encryption off,
  NetworkManager DHCP/DNS, active QEMU guest agent, identical ESP boot binaries,
  user-owned deployment/resources, mode-0600 root-owned target log, and no
  leftover service-start policy, encryption key or encryption hook.
- TTY1 displayed a normal login prompt. Logging in started Hyprland 0.55.2 and
  Noctalia 5.3.0 as the configured account; their desktop and Alacritty rendered
  with Virtio graphics/software rendering. Super+M ended Hyprland and returned
  to the same TTY1 Zsh shell. Snapshot and EFI-sync services were active.
- A further boot with only the second mirror member reached normal TTY1 login
  and working NetworkManager/guest-agent services with a degraded pool. The
  second ESP and its boot binary remained intact; the present member's swap
  was active. EFI synchronization did not run with the primary ESP missing.
  Missing-device timeouts delayed this degraded boot (swap retains systemd's
  default device timeout).
- Testing exposed live udev/logind mount-namespace references that blocked pool
  export; the installer now owns a recursively private mount namespace. Cleanup
  retries also avoid writing logs beneath an already-unmounted target. Both
  cases are covered by regression checks and the subsequent guest export.

## Startup and display follow-up (2026-10-19)

- All 26 functional/PTY tests passed on the development host and in a fresh
  Debian Trixie container. Deployment dry runs passed for all five GPU profiles.
- Bash syntax checks and ShellCheck 0.11.0 passed for the installer, libraries,
  deployment and test scripts; `git diff --check` passed.
- A minimal Debian container without `loadkeys`, `setupcon` or XKB layout data
  accepted the initial console-keyboard choice without installing packages.
  Definitive validation remains after dependency installation and before disk
  changes.
- PTY tests exercised verbose output at 90 columns, resize to 65 columns,
  stage transitions and interrupt. Frame fixtures also checked 40 columns /
  10 rows, control-sequence removal, standard-console final review and waiting
  for an in-flight renderer pipeline before returning from a stage.
- Secure Boot enabled/disabled detection used EFI-variable fixtures. Module
  signature rejection used a mocked `modprobe`; actual firmware/signing-key
  enrollment was not tested. This installer requires Secure Boot disabled.
- The full UEFI guest installations above apply to the initial implementation.
  They were not repeated for this startup/display change.

## Void-style interface (2026-10-19)

- All 27 functional/PTY tests passed on the host and in disposable Debian
  Trixie containers, including a run with `LC_ALL=C`. All five deployment GPU
  dry runs, Bash syntax, ShellCheck 0.11.0 and `git diff --check` passed.
- PTY checks verify green titles, yellow bracketed values, purple stage
  headings, blue log notes, red failures, `NO_COLOR`, terminal resizing,
  interrupts and valid Unicode clipping. Logs retain full output and stages
  stop on failure; the on-screen preview contains at most five recent lines.
- Configuration and installation previews were captured from 80x24 PTYs,
  rendered with the pyte terminal emulator and visually inspected. The full
  mirror/VM/encryption configuration and final confirmation fit on screen.
- VT allocation and completed-step history were removed at the user's request.
  The reference repository was read without modification. Full installations
  and physical GPU checks were not repeated for these interface changes.

Physical GPU tests (especially NVIDIA), Secure Boot enrollment, VMware guest
integration, and physical-machine installation were not performed. GPU profiles
other than the VM profile were validated with dry runs, APT simulations and
mocked chroot execution, not with physical hardware. BIOS installation remains
intentionally unsupported. DHCP-off is covered with fixtures rather than a
separate installed guest.
