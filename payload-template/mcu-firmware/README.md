# MCU firmware payload

`common/flash-mcu-firmware.sh` (run by `installers/soc/05-flash-mcu-firmware.sh`
and `installers/tunnel/05-flash-mcu-firmware.sh`) expects exactly one
package here:

```text
<name>.tgz
<name>.tgz.sha256
<name>.tgz.manifest.json
```

This is the encrypted FlashForge update format built by
[`creator-5-update-creator`](https://github.com/FlashForge-C5-Modding-Group/creator-5-update-creator),
with the stock MCU images replaced by klipper-c5 builds
(`MCU_MODE=replacement`). The script decrypts it with the known
Creator 5 Pro update password, extracts the inner `control-*.tar.xz`,
and flashes each board with the bundled `IAPCommand`/`ISPCommand`
exactly as a stock firmware update would -- just skipping the
touchscreen-era bookkeeping (splash images, the long `sleep` on
failure) that its `run.sh` does for an attended update.

For local testing, copy one of the example packages already sitting at
the root of the Klipperstuffs workspace into this directory, e.g.:

```sh
cp Creator5Pro-all-mcus-b4c9c5e9-20261008.tgz \
   Creator5Pro-all-mcus-b4c9c5e9-20261008.tgz.manifest.json \
   payload-template/mcu-firmware/
sha256sum Creator5Pro-all-mcus-b4c9c5e9-20261008.tgz \
   > payload-template/mcu-firmware/Creator5Pro-all-mcus-b4c9c5e9-20261008.tgz.sha256
```

The script reads the firmware's `repository.commit` from the manifest
and records it in `/usr/data/opencreator/mcu-firmware.commit` once
flashed, so re-running the installer with the same package is a no-op.
Leave this directory empty to skip MCU flashing entirely (the step
prints a STAGE message and exits 0).
