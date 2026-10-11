# OpenCreator installer

An LVGL 8.3 touchscreen installer for the Creator 5. The application renders
directly to `/dev/fb0` and reads `/dev/input/event0`; it does not require X11,
SDL, or GrumpyScreen. LVGL is pinned as a Git submodule at `vendor/lvgl`.

The flow is:

1. Verify the supplied squashfs against a `.sha256` sidecar. If the recorded
   image is already installed, skip it. Otherwise stage a rootfs-only update
   through the stock OTA helper and reboot. Reopen this app after reboot.
2. Choose installation on the printer SoC or tunnel mode.
3. In SoC mode, choose Mainsail or Fluidd, then whether to install the
   recommended GrumpyScreen touchscreen. Tunnel mode skips both questions.
4. Back up `/usr/prog/klipper`, `/usr/prog/PROGRAM`, and `/usr/data/config`
   before running any install script.
5. Run the ordered `.sh` files from `payload/installers/soc` or
   `payload/installers/tunnel`, showing `STAGE` and `ERROR` output on screen.

The completed installation writes `/usr/data/opencreator/install.json`, with
installer version, mode, web UI, touchscreen choice, rootfs SHA-256, UTC time,
and backup location.
The rootfs checkpoint lives at `/usr/data/opencreator/rootfs.state`. It is
considered current only when its digest matches and the vendor OTA version has
reached the staged version.

## Build

```sh
git submodule update --init --depth 1
make
make mips32
file build/mips32/opencreator-installer
```

For an x86-64 Linux SDL preview (install `libsdl2-dev`):

```sh
make sdl
./build/sdl/opencreator-installer
```

Run from the project root. The SDL binary is compiled with `OC_DEMO` and
always uses `scripts/demo.sh`, so it cannot invoke the real install backend.
Set `OC_DEMO_ROOTFS=1` to also preview the rootfs/reboot page. Its countdown
returns to the flow without rebooting the host.

`make mips32` uses `mipsel-linux-gnu-gcc` for the printer's little-endian
MIPS32r2 userland and links statically to avoid a host glibc mismatch. For
the printer's exact sysroot, pass `CROSS_COMPILE` and `CFLAGS` from its
Buildroot toolchain. The app is not yet claimed to be hardware-tested.

## Payload layout

```text
payload/
  vendor/local_ota_update.sh        # stock vendor OTA orchestration script
  installers/soc/*.sh              # ordered on-printer steps
  installers/tunnel/*.sh           # ordered tunnel steps
  soc/install-stack.sh             # example wrapper target
  soc/install-web.sh               # example wrapper target
  tunnel/install-tunnel.sh         # example wrapper target
```

`payload-template/installers` supplies separate mode-specific wrappers,
including the SoC-only `30-install-grumpyscreen.sh`. Its offline installer is
adapted from `opencreator-fs/scripts/installgrumpy.sh`, but requires a
checksum-verified `payload/soc/grumpyscreen.tar.gz` instead of downloading an
unverified release during installation. The
actual Klipper, web UI, and tunnel payloads are release inputs, not guessed
or downloaded by this app. A missing installer fails visibly and leaves the
backup intact. Scripts can emit `STAGE message` to show progress.

The rootfs updater needs the stock `/etc/ota_bin` helpers on the printer and
the stock `local_ota_update.sh` copied into `payload/vendor`. It generates an
OTA package with only `img_type=rootfs`, so it does **not** write a hardcoded
eMMC partition or update the kernel. The supplied image must have a sidecar
named exactly `rootfs.squashfs.sha256` containing its 64-character SHA-256.
The image is staged under `/usr/data/opencreator` and requires enough free
space there for a full copy. The backup destination must exist and be
writable; use an external USB mount for recoverability.

Run as root, with no other touchscreen UI active:

```sh
opencreator-installer /media/usb/rootfs.squashfs \
  /media/usb/opencreator-payload /media/usb/backups \
  /usr/data/opencreator/scripts/install.sh
```

The squashfs argument may be `-` to skip rootfs installation entirely. This
is appropriate when the required rootfs is already on the printer. The
install backend can be tested without the UI using:

```sh
/bin/sh scripts/install.sh check - payload-template /tmp/backups soc mainsail
```

Do not start this on a printer until the vendor OTA package and both mode
payloads are reviewed and the backup destination is verified. A power loss
during the rootfs update remains a firmware recovery risk.
