# OpenCreator installer

An LVGL 8.3 touchscreen installer for the Creator 5. The application renders
directly to `/dev/fb0` and reads `/dev/input/event0`; it does not require X11,
SDL, or GrumpyScreen. LVGL is pinned as a Git submodule at `vendor/lvgl`.

The flow is:

1. Check the printer model and the FlashForge kernel package (see below).
   On an unsupported kernel package, stop without changing anything.
2. Choose installation on the printer SoC or tunnel mode.
3. In SoC mode, choose Fluidd (recommended) or Mainsail. In both modes, choose whether to
   install the recommended GrumpyScreen touchscreen. With tunnel mode, the
   finish page says to set `host` under `[moonraker]` in
   `/usr/data/grumpyscreen/grumpyscreen.cfg` to the SBC.
4. Back up `/usr/prog/PROGRAM`, `/usr/prog/moonraker`, `/usr/data/opencreator`,
   `/usr/data/mainsail`, `/usr/data/fluidd`, `/usr/data/nginx` and
   `/usr/prog/c5-tunnel-socat` before running any install script.
5. Run the ordered `.sh` files from `payload/installers/soc` or
   `payload/installers/tunnel`, showing `STAGE` and `ERROR` output on screen.

The printer's root filesystem is not changed. Everything is installed on the
writable `/usr/prog` and `/usr/data` partitions, and the printer needs
internet during the install.

The completed installation writes `/usr/data/opencreator/install.json`, with
installer version, printer model and PID, kernel package, mode, web UI,
touchscreen choice, UTC time, and backup location.

## What each mode installs

Both modes start with:

1. **Entware** (`common/install-entware.sh`), as in the Creator-5-Mods
   "Add Entware Package Manager" guide: set the clock, enable legacy NaN,
   bind-mount `/usr/data/bin/opt` on `/opt`, run Entware's `generic.sh`, then
   `opkg install` git, curl and gcc (plus Python and Moonraker's build
   dependencies in SoC mode, or socat in tunnel mode). Entware's compiler
   headers go in `/opt/include`, and `/etc/profile` gets `/opt/bin` on `PATH`.
   An existing Entware is reused.
2. **LoopScript** (`common/install-loopscript.sh`): opencreator-fs's
   `firmwareExe` replaces `/usr/prog/PROGRAM/software/firmwareExe` (the stock
   binary is kept once as `/usr/data/opencreator/firmwareExe.stock`), with its
   `startup/`, `tunneled/` and `moonraker/` folders in `/usr/data/opencreator`,
   and the nginx snippets in `/usr/data/nginx/conf.d`.
3. **MCU firmware**, from the package on the drive, if any.

SoC mode then installs:

- **Kalico** (`soc/install-stack.sh`): the `something` branch in
  `/usr/data/opencreator/klipper/klipper`, a `klippy-env` virtualenv on
  Entware's Python with Kalico's requirements, and the built C helper. The
  opencreator-fs printer config goes in `/usr/data/opencreator/klipper/config`;
  files that already exist there are kept. Logs go in `.../klipper/logs`, and
  `.../klipper/gcodes` links to `/usr/data/gcodes`.
- **Moonraker** (`soc/install-moonraker.sh`), as in the "Update Moonraker"
  guide: current Moonraker in `/usr/prog/moonraker/moonraker` with a
  `moonraker-env` virtualenv on Entware's Python.
- **Web UIs** (`soc/install-web.sh`): the latest Mainsail in
  `/usr/data/mainsail` and Fluidd in `/usr/data/fluidd`. The nginx site
  (`/usr/data/nginx/sites-available/mainsail`) serves the chosen one on port 80.
- **GrumpyScreen**, if chosen.

Tunnel mode then installs:

- **The socat bridge** (`tunnel/install-tunnel.sh`): `c5_socat.py` from
  opencreator-tunnel's `printer-socat` in `/usr/prog/c5-tunnel-socat`, with
  `identify_monitor` built by Entware's gcc. Making
  `/usr/data/opencreator/tunneled/tunneled.sh` executable switches the board to
  bridge-only mode.
- **GrumpyScreen**, if chosen.

`OC_FS_REPO`, `OC_TUNNEL_REPO`, `OC_KALICO_REPO` and `OC_KALICO_BRANCH`
override where these are downloaded from.

## Boot (LoopScript)

`firmwareExe` boots the SoC coprocessor and joins Wi-Fi. If `tunneled.sh` is
executable it runs that; otherwise it runs `startup/startup.sh`, which starts
every `startup/scripts/*.sh` in the background:

| Script | Does |
| --- | --- |
| `01-fixnan.sh` | Enables legacy NaN for the kernel package |
| `02-fixtime.sh` | Sets the clock once the network is up |
| `05-entfix.sh` | Enables legacy NaN, mounts Entware on `/opt`, starts its services |
| `08-mcu-wake.sh` | Wakes MCUs that Klipper can't reach |
| `10-klipper.sh` | Runs Kalico from `klippy-env` (`-a /tmp/uds`), restarting it if it exits |
| `20-msmr.sh` | Starts nginx, and runs Moonraker from `moonraker-env` with `-d /usr/data/opencreator/klipper` |
| `25-fluidd-macros.sh` | Once Moonraker is up, gives Fluidd the OpenCreator macro layout if it has none |
| `30-camera.sh` | Starts the webcam |
| `40-grumpyscreen.sh` | Runs GrumpyScreen on the touchscreen's input device, if installed |
| `99-opencreator-updater.sh` | Merges config template updates |

`tunneled.sh` runs `05-entfix.sh`, the camera and GrumpyScreen, then the socat
bridge in a restart loop.

## Printer model detection

The `check` step reads `MACHINE=` and `PID=` from the stock
`/usr/prog/app_startup.sh` (falling back to
`/usr/prog/PROGRAM/runFirmwareExe.sh`). Only these pairs are accepted:

| Model         | MACHINE       | PID    |
|---------------|---------------|--------|
| Creator 5     | `Creator5`    | `0028` |
| Creator 5 Pro | `Creator5Pro` | `0029` |

The detected model is shown in the header and on the Ready page, and is passed
to every payload script as `OC_MACHINE` and `OC_PID`. If neither pair is found,
installation is refused. `OC_MACHINE`/`OC_PID` in the environment override
detection; demo installs default to `Creator5Pro`.

## Kernel check

Entware's binaries need legacy NaN, which is switched on by writing one byte
with `busybox devmem` at an address that depends on the FlashForge kernel
package (`/usr/prog/PROGRAM/kernel/<version>`):

| Kernel package | Address |
| --- | --- |
| 2.0.1 to 2.0.6 | `0x00a130d1` |
| 2.0.7 (FlashForge 1.9.9) | `0x00B330D1` |

On any other package the installer stops on *Unsupported FlashForge firmware*,
and LoopScript's `01-fixnan.sh` writes nothing. `OC_KERNEL_PACKAGE` overrides
the detected package; demo installs default to 2.0.7. In the SDL demo,
`OC_DEMO_OLD_KERNEL=1` previews the refusal page.

## Other features

- **Preflight warnings**: `check` warns about less than 256 MB free on
  `/usr/data` or the backup drive (`OC_MIN_FREE_KB` overrides the threshold),
  a missing or read-only backup destination, and missing installer scripts.
- **Progress bar and elapsed time** while installing or restoring.
- **Log viewer**: the Log button (top right) shows all backend output. The
  same output is appended, timestamped, to `BACKUP_DIR/opencreator-installer.log`
  (or `/tmp/opencreator-installer.log` if that is not writable).
- **Restore backup**: when a previous OpenCreator backup exists (the one in
  `install.json`, otherwise the newest `BACKUP_DIR/opencreator-*`), the mode
  page and the error page after a failed install offer to restore it. Folders
  that did not exist at backup time (listed in `absent.list`) are removed.
  MCU firmware is not rolled back.
- **Reboot now** button once installation or restore completes.

### Backend output protocol

Lines written by `scripts/install.sh` and payload scripts:

| Line                   | Effect                                     |
|------------------------|--------------------------------------------|
| `STAGE text`           | Status line                                |
| `ERROR text`           | Status line in red                         |
| `WARN text`            | Preflight warning on the mode page         |
| `PROGRESS n total`     | Progress bar                               |
| `MODEL machine pid`    | Detected printer model                     |
| `KERNEL OK/MISMATCH package` | Whether the kernel package is supported |
| `BACKUP path`          | Enables Restore backup                     |

## Touch input

The app reads the first input device named goodix or touch in
`/proc/bus/input/devices` (`event2` on the Creator 5, where `event0` is the
camera), falling back to `/dev/input/event0`. `OC_TOUCH_DEV` overrides it.

## Logo

`src/logo.c` is generated from `opencreator-oc-white.svg` by
`scripts/gen-logo.py` (pure Python, no dependencies) as two 8-bit alpha
images, tinted at runtime. Regenerate after changing the SVG with `make logo`.

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

`make mips32` uses the Ingenic xburst2 toolchain (r6.0.0, GCC 12.1, glibc
2.33), the same one the stock kernel was built with. Extract
`mips-xburst2-linux-toolchain-r6.0.0.tar.bz2` into
`../ingenic-mips-toolchain-r6.0.0/`, or point `INGENIC_TOOLCHAIN` at the
extracted `mips-xburst2-linux-toolchain-r6.0.0` directory. It builds with
`-mnan=2008` (no legacy NaN, matching the stock userland) and links
statically. `readelf -h` should list `nan2008, o32, mips32r2`. The app is
not yet claimed to be hardware-tested.

## Payload layout

```text
payload/
  installers/soc/*.sh              # ordered on-printer steps
  installers/tunnel/*.sh           # ordered tunnel steps
  common/install-entware.sh        # Entware and legacy NaN (both modes)
  common/install-loopscript.sh     # opencreator-fs LoopScript (both modes)
  common/flash-mcu-firmware.sh     # MCU firmware (both modes)
  soc/install-stack.sh             # Kalico and printer config
  soc/install-moonraker.sh         # Moonraker
  soc/install-web.sh               # Mainsail, Fluidd and the nginx web root
  soc/installgrumpy.sh             # GrumpyScreen (both modes)
  tunnel/install-tunnel.sh         # socat bridge
```

The wrappers in `payload-template/installers` run in name order: Entware
first, since every later step needs its git. Both modes have
`30-install-grumpyscreen.sh`, which runs `soc/installgrumpy.sh` when the
touchscreen was chosen: it downloads the latest GrumpyScreen release and checks
that it is an ELF binary. Everything except the MCU firmware package (a
release input on the drive) is downloaded during the install. A missing
installer fails visibly and leaves the backup intact. Scripts can emit
`STAGE message` to show progress. The backup destination must exist and be
writable; use an external USB mount for recoverability.

Run as root, with no other touchscreen UI active:

```sh
opencreator-installer /media/usb/opencreator-payload /media/usb/backups \
  /usr/data/opencreator/scripts/install.sh
```

The install backend can be tested without the UI using:

```sh
/bin/sh scripts/install.sh check payload-template /tmp/backups soc mainsail
```

The latest backup can be restored the same way with the `restore` action.
`scripts/demo-install.sh [MODE] [WEB] [TOUCHSCREEN]` runs a whole install in
demo mode under `./demo-root`. Demo mode still downloads from GitHub but skips
Entware, the NaN switch and anything that needs the printer.

Do not start this on a printer until both mode payloads are reviewed and the
backup destination is verified.
