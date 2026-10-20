# Debian ZFS live image

`build.sh` builds the amd64 Debian 13 Trixie UEFI live ISO. The live desktop is
configured by the bundled `deploy/deploy.sh`, package arrays in
`deploy/vars.sh`, and the repository dotfiles. The live session uses the Intel
profile for its generic Mesa desktop; the ISO's local APT repository includes
all five installer GPU profiles, including both VM guest integrations.

The image also contains the installer and a tarball for debootstrap's Debian
base packages. During installation, the ISO is mounted read-only into the
target chroot and APT pins its matching package repository, so base, kernel,
ZFS and desktop packages use the bundled archives. A standard Debian live
image without this cache follows the existing mirror-based installation path.

The build needs a root Debian 13 Trixie amd64 environment with network access.
The GitHub Actions workflow provides it in a privileged Debian container. To
build locally, use a disposable Debian Trixie VM or container and mount this
checkout at `/workspace`:

```sh
docker run --rm --privileged \
  --volume "$PWD:/workspace" \
  --workdir /workspace \
  debian:trixie-slim \
  bash /workspace/image/build.sh
```

The build downloads current Debian, backports and Noctalia packages, so the
result reflects repository configuration and package availability at build
time. `image/package-manifest.sh` reads `deploy/vars.sh` directly; it does not
maintain a second desktop package list. Generated files are written to ignored
`dist/` and `/tmp/debianzfs-live-build/`.

Push a version tag matching `v*` to run the release workflow. It attaches the
ISO and `SHA256SUMS` to a GitHub Release. If the ISO reaches 1,900 MiB, CI splits
the release copy into 1,800 MiB parts; the Actions artifact retains the complete
ISO. Release assets include instructions to reassemble split files.

The build and tests do not establish support for every physical GPU. Secure Boot
must be disabled, matching the installer requirements.
