> Note: all of this was ported from my voidzfs-install which is more polished jsuk where weird styling in the installer comes from.

0. Download the latest Debian 13 Standard Live Image: e.g. <https://saimei.ftp.acc.umu.se/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.7.0-amd64-standard.iso>
1. Boot Debian13 - Standard Live Image (e.g. `debian-live-13.7.0-amd64-standard.iso`)
2. setup wifi from cli or just use a wired connection
3. make sure your keyboard layout is correct (z->y etc.)
4. `sudo apt update`
5. `sudo apt install git`
6. `git clone https://github.com/foelkdavid/debianzfs-install`
7. `cd debianzfs-install`
8. `sudo ./install.sh`
9. Wait a bit to get to the interactive part - this can take some time depending on your system since it has to build some modules
10. Run throught the interactive installer.

    If you dont need a Raid 1 mirror, just select no.

    Unless you have very little RAM i dont see a point in using partitioned swap so just use 0.

11. Wait..
12. Reboot!.
