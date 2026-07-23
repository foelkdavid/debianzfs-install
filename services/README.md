# Services

The Debian installer provides two native systemd services:

1. `efisync.service`
   - Installed only for mirrored systems.
   - Keeps `/boot/efi2` synchronized from `/boot/efi`.

2. `zfs-autosnap.service`
   - Runs snapshot jobs from `/etc/zfs-autosnap/jobs.conf`.
   - Preserves the original pipe-delimited job format.
