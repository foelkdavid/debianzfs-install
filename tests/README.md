# Validation

Host-safe functional and pseudo-terminal tests (Python 3 and Bash required):

```sh
python3 tests/test_installer.py
python3 tests/test_noctalia_bundle.py
python3 tests/test_hyprland.py
python3 tests/test_boot.py
```

Terminal-emulator regressions additionally require the `pyte` Python package
(`python3-pyte` on the Debian test system):

```sh
python3 tests/test_terminal.py
```

These tests check actual screen cells after redraws, short/long output,
configuration-to-installation transitions, resize, changed terminal newline
processing and interrupts during the first redraw. They use harmless stage
fixtures; `pyte` is a test dependency, not an installer UI dependency.

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

Hyprland tests additionally use Lua 5.4 to execute the config with mocked
monitor and dispatcher APIs. They cover startup without monitors, one to three
monitors, per-monitor number/move/wheel bindings, disconnect/reconnect, reload,
directional focus/swap, and every static hardware profile. User setup runs with
a temporary HOME to check profile symlinks, migration from generated files,
profile switching, ownership, and saved settings. These tests do not reload the
host compositor or establish physical multi-monitor/GPU compatibility.

Boot tests require Pillow (`python3-pil` on Debian) for image checks. They verify
that Plymouth packages are cached for the live and clean target systems, the
stock spinner is selected in the target before the final initramfs rebuild,
`quiet splash` is passed through ZFSBootMenu without changing encryption unlock
properties, and both bootloader overrides receive valid RGB PNG backgrounds.
All target writes and ZFS commands use temporary roots or mocks.

Syntax/static checks:

```sh
bash -n install.sh
for file in lib/*.sh deploy/*.sh deploy/scripts/*.sh tests/*.sh \
  debianzfs-config/*.sh debianzfs-config/scripts/*/*.sh; do bash -n "$file"; done
shellcheck -x install.sh lib/*.sh deploy/*.sh deploy/scripts/*.sh tests/*.sh \
  debianzfs-config/*.sh debianzfs-config/scripts/*/*.sh
```

Run the following only in **disposable Debian Trixie containers**. They require
root and deliberately refuse other environments. The repository can be mounted
read-only at `/repo`; install their dependencies in the disposable container.

- `bash /repo/tests/container-check.sh`: requires `zsh`, `systemd`, `sudo`,
  `python3`, `xdg-user-dirs`, `procps`. Uses mocked package/download commands
  with real `runuser`, file ownership, Zsh and offline systemctl links. Exercises
  all five chroot profiles plus the software-rendered VM variant, HOME/XDG
  identity, permanent dotfile links, saved settings, package-failure policy
  restoration, incompatible target NVIDIA
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

## NVMe pool-device resolution (2026-10-20)

- All 37 installer tests passed, including missing/invalid UUIDs, delayed block
  nodes/probes, missing udev aliases, NVMe partition numbering with swap,
  missing/duplicate mirror members, partition reread/udev failures, and pool
  failure status/ownership. Bash syntax and ShellCheck passed.
- A Debian live guest with two new emulated NVMe disks passed eight native
  partition/pool/dataset tests: single/mirror × swap off/on × encryption off/on.
  Each case created and mounted the datasets, exported/reimported the pool,
  and destroyed only its disposable test pool.
- The old code reproduced the reported empty `/dev/disk/by-partuuid/` error
  when a failed UUID lookup was injected in that VM. Fresh uninjected NVMe
  probing succeeded there, so the laptop's underlying lookup failure has not
  been reproduced or diagnosed on physical hardware.
- These are storage-stage tests, not new full installations or reboot tests.

## Plymouth and ISO menu appearance (2026-10-20)

- Four new boot tests and all 31 installer tests passed on the development
  host. The four boot tests also passed in a disposable Debian Trixie container.
- ShellCheck and Bash syntax checks passed for the changed scripts.
- The container selected the stock `spinner` theme and rebuilt a real Debian
  6.12.113 initramfs. `lsinitramfs` confirmed the theme, animation images,
  Plymouth binaries/configuration, and init-premount/init-bottom/panic scripts.
- A menu-only fixture used Debian live-build to generate the GRUB configuration;
  `grub-script-check` passed. Diskless QEMU guests displayed the themed UEFI
  GRUB and BIOS Syslinux menus. This validates menu rendering, not BIOS target
  installation support.
- No complete live ISO rebuild, full live/installed-system Plymouth boot,
  encrypted-ZFS reboot, or physical-GPU validation was performed for this
  change. The graphical splash still depends on working framebuffer/KMS support.

## Minimal Hyprland configuration (2026-10-20)

- Lua 5.4 syntax checks and ShellCheck passed for the changed configuration,
  deployment script, and container fixture.
- All 31 installer tests (including every GPU deployment dry run), five
  Noctalia tests, and three new Hyprland tests passed on the development host.
- A disposable Debian Trixie container passed all six profile deployment
  scenarios with real user ownership and offline service links, failure-policy
  restoration, NVIDIA target-kernel checks, login guards, and EFI sync guards.
- All six terminal-emulator regressions passed in the container. The new Lua
  callback and profile-selection tests also passed as its normal fixture user.
- Hyprland's configuration verifier passed for the default configuration and
  all six hardware profiles on Debian's Hyprland 0.55.2 and host Hyprland 0.56.2.
- Monitor events and workspace actions were tested with mocks. No new VM
  installation, image rebuild, physical multi-monitor, or physical GPU test was
  performed for this change. The missing-GPU crash report remains a separate
  backend/device issue; this change avoids the master-layout cycling path in
  the other report without claiming to fix all compositor crashes.

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

## Redraw regression fixes (2026-10-19)

- The 27 functional/PTY tests passed on the host and Debian Trixie. Six new
  terminal-emulator tests passed in Debian, including both `-onlcr` and
  `-opost` modes and a resize from 80x24 to 50x12. Bash syntax checks,
  ShellCheck 0.11.0 and `git diff --check` passed.
- Before the fix, emulator tests reproduced stale configuration rows and
  duplicate headings/log paths after terminal newline processing changed.
  After the fix, screen cells contain exactly one heading and log path,
  with blank rows and old trailing text fully cleared.
- Tests also cover stage stdin isolation, exact terminal-mode restoration,
  interrupting before command launch and full output logging. The FIFO reader
  is opened before launch so interrupts and very short stages cannot strand
  the logger waiting for an output writer.
- Full guest installations and physical GPU validation were not repeated for
  this display/runner change.

Physical GPU tests (especially NVIDIA), Secure Boot enrollment, VMware guest
integration, and physical-machine installation were not performed. GPU profiles
other than the VM profile were validated with dry runs, APT simulations and
mocked chroot execution, not with physical hardware. BIOS installation remains
intentionally unsupported. DHCP-off is covered with fixtures rather than a
separate installed guest.
