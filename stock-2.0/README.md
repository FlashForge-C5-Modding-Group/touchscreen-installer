# Stock 2.0 USB drive

A standalone USB drive, separate from the OpenCreator installer, that puts a
Creator 5 or Creator 5 Pro back on FlashForge 2.0.0's firmware and MCU firmware.
The kernel is not changed.

## Using it

1. Extract the zip to the root of a FAT32 USB drive (only these files, not the
   OpenCreator installer).
2. Plug it in and power the printer on. The stock boot runs `runFirmwareExe.sh`,
   which installs everything (about a minute), then reboots.
3. On that reboot the stock boot flashes the four boards (control 1.3.1) and
   reboots again into FlashForge's firmware.
4. Unplug the drive. The script renamed itself to `runFirmwareExe.sh.done`, so
   it doesn't run again; rename it back to use the drive again.

The log is `stock-2.0.log` on the drive. If anything is wrong before installing
(wrong model, damaged files, under 128 MB free on `/usr/data`), nothing is
changed and the printer boots as before.

## What it installs

From FlashForge 2.0.0, taken from the public
`creator-5-firmware-archive` / `creator-5-pro-firmware-archive`:

- **software 2.0.0**: firmwareExe (`/usr/prog/PROGRAM/software/firmwareExe`, and
  `software/2.0.0/`), FlashForge's Klipper (`/usr/prog/klipper/klippy`,
  `start.sh`, `klipper_pri.sh`), its `printer.*.cfg` includes in
  `/usr/data/config`, `app_startup.sh`, `/usr/prog/bin`, the Wi-Fi module, and
  the stock `passwd`/`shadow` (OpenCreator's SSH login is gone afterwards).
- **control 1.3.1**: the eBoard, heaterBoard, levelBoard and mainBoardGD
  firmware with FlashForge's IAPCommand/ISPCommand, flashed by the stock boot.

Not installed: the kernel (stays as it is, e.g. 2.0.7 on 1.9.9) and the library
(1.2.5 in both 1.9.9 and 2.0.0). FlashForge pairs software 2.0.0 with kernel
2.0.8, so on an older kernel this isn't FlashForge's exact 2.0.0 install.

OpenCreator's files (`/usr/data/opencreator`, GrumpyScreen, python-hf) stay on
the printer, unused. Its install record becomes `install.json.rolled-back`, so
the installer offers a fresh install.

## Building it

In WSL or Linux, with git, tar and python3:

```sh
sh stock-2.0/make-usb.sh            # writes dist/stock-2.0-usb
```

It sparse-clones both archives to `~/ffarch` (`OC_FF_ARCHIVES` to change it)
and checks every file FlashForge's `md5sum.list` covers (all of control, the
boot script, bin, auth, the Klipper scripts and configs) against it before
packing. Klipper's Python files and firmwareExe come from zips FlashForge's list
only has whole, so they aren't checked file by file. `start.img` and `end.img`
(the update screens) come from `creator-5-update-creator/template`.
