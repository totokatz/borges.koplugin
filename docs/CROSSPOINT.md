# Borges en CrossPoint

**Para Xteink X4.** Borges está integrado en una versión de CrossPoint; se instala como firmware, no como una carpeta `.koplugin`.

**[Descargar firmware para X4 →](https://github.com/runadev-arg/crosspoint-toto/releases/download/toto-v1.4.1-toto.1/firmware.bin)** · [Release y archivos de recuperación](https://github.com/runadev-arg/crosspoint-toto/releases/tag/toto-v1.4.1-toto.1) · [Volver a las descargas](../README.md)

## Qué estás descargando

| | |
| :--- | :--- |
| Dispositivo | **Xteink X4 / ESP32-C3** |
| Versión publicada | **1.4.1-toto.1** |
| Archivo | `firmware.bin` |
| Integración en el menú | **Toto Sync** (nombre anterior de Borges Sync) |
| Tamaño | 5.750.672 bytes |
| SHA-256 | `90928530d54e4f0efbcb72558e19aad1080db83f09c3bffc2d7ef6f42cad654c` |

Este archivo no corresponde al X3 ni a otros lectores. El enlace apunta a una versión concreta para que el modelo, las instrucciones y el checksum siempre correspondan al mismo archivo.

## Instalar

1. Guardá una copia de la microSD y descargá `firmware.bin` con el enlace de arriba.
2. Compará el SHA-256 con el valor publicado en esta página y en los [checksums de la release](https://github.com/runadev-arg/crosspoint-toto/releases/download/toto-v1.4.1-toto.1/SHA256SUMS).
3. Conectá el X4 por USB-C a la computadora y despertalo.
4. Abrí las [herramientas de instalación de CrossPoint](https://crosspointreader.com/#flash-tools). Elegí **X4 → Custom .bin** y seleccioná el archivo descargado.
5. Esperá a que termine y reinicie sin desconectar el cable. Conectá el lector a Wi-Fi y abrí **Toto Sync** para configurar la conexión con Borges siguiendo las indicaciones de esa versión.

> **Si tu X4 tiene el USB bloqueado de fábrica:** no uses este firmware personalizado con el desbloqueador. CrossPoint advierte que su herramienta de desbloqueo sólo admite los firmwares oficiales que indica y que instalar otro puede impedir la recuperación. Consultá primero sus [instrucciones para equipos bloqueados](https://github.com/crosspoint-reader/crosspoint-reader#usb-locked-devices-xteink-unlocker).

Para calcular el checksum:

```powershell
# Windows
Get-FileHash .\firmware.bin -Algorithm SHA256
```

```sh
# macOS
shasum -a 256 firmware.bin
# Linux
sha256sum firmware.bin
```

## Actualización y recuperación

Conservá una copia del firmware que usabas antes. La [release original](https://github.com/runadev-arg/crosspoint-toto/releases/tag/toto-v1.4.1-toto.1) incluye `firmware-known-good.bin` y su checksum para recuperación. Verificá siempre modelo y archivo antes de instalar; no uses el ZIP de KOReader en el X4.

CrossPoint es un proyecto de [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader). La integración de Borges se distribuye desde [crosspoint-toto](https://github.com/runadev-arg/crosspoint-toto), con su licencia y atribuciones originales.
