#!/usr/bin/env bash
# Real APT simulations in a fresh disposable Trixie container, no desktop install.
set -Eeuo pipefail
[[ -f /.dockerenv && $EUID == 0 ]] || { echo 'Disposable root Docker container required.' >&2; exit 1; }
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates python3
python3 "$REPO/deploy/scripts/debian-sources.py" /etc/apt --write
curl -fL https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb -o /tmp/noctalia-keyring.deb
dpkg -i /tmp/noctalia-keyring.deb
curl -fL https://pkg.noctalia.dev/deb/noctalia-trixie.sources -o /etc/apt/sources.list.d/noctalia-trixie.sources
apt-get update
for profile in intel amd nvidia nouveau vm; do
    plan=$(GPU_DRIVER=$profile VM_GUEST=qemu bash "$REPO/deploy/deploy.sh" --dry-run)
    read -r -a normal <<< "$(sed -n 's/^Packages: //p' <<< "$plan")"
    read -r -a backports <<< "$(sed -n 's/^Backports: //p' <<< "$plan")"
    read -r -a noctalia <<< "$(sed -n 's/^Noctalia: //p' <<< "$plan")"
    requests=()
    for package in "${normal[@]}" "${noctalia[@]}"; do
        case $package in
            libgl1-mesa-dri|libegl-mesa0|mesa-*|nvidia-*|libnvidia-*|pipewire-*|wireplumber|libspa-0.2-bluetooth)
                requests+=("$package") ;;
            *)
                candidate=$(apt-cache policy "$package" | awk '$1 == "Candidate:" {print $2; exit}')
                [[ -n $candidate && $candidate != '(none)' ]]
                requests+=("$package=$candidate") ;;
        esac
    done
    for package in "${backports[@]}"; do requests+=("$package/trixie-backports"); done
    apt-get --simulate -t trixie-backports install --no-install-recommends "${requests[@]}" > "/tmp/plan-$profile.log"
    echo "PASS: actual APT transaction simulation ($profile)"
done
