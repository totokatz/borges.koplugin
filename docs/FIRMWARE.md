# Borges for Xteink X4

[Download borges-x4.bin](https://github.com/runadev-arg/borges-firmware/releases/latest/download/borges-x4.bin) · [Release notes and checksums](https://github.com/runadev-arg/borges-firmware/releases/latest) · [Source code](https://github.com/runadev-arg/borges-firmware)

Borges is the firmware installed on the reader. The KOReader ZIP is a separate download and does not install on an X4.

## Install

1. Back up your microSD card. This download is for **Xteink X4**.
2. Download `borges-x4.bin` and compare its SHA-256 against the release checksum file.
3. Connect the X4 by USB. If your current firmware supports installing a `.bin` from the SD card, use its firmware update screen. Otherwise, open the [upstream flashing tool](https://crosspointreader.com/#flash-tools), choose **X4 → Custom .bin**, and select the downloaded file.
4. Keep the device connected until installation finishes. Restart into **Borges**.
5. Connect Wi-Fi and open **Settings → System → Borges → Pair device**. Approve the code in your [Borges account](https://borges.runadev.com/devices/pair), then choose **Sync now**.

For factory USB-locked devices, follow the upstream device-specific preparation instructions before attempting a custom firmware installation. Do not select another hardware model.

## Existing installations

Borges migrates the previous settings directory, saved connection and synchronization queue on first boot. Keep your backup until you have checked your library and annotations. If migration cannot complete, it stops and asks you to retry rather than starting with empty settings.
