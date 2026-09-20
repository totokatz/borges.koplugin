# Publicar Borges para KOReader

## Contrato del paquete

- Descarga recomendada: `borges.koplugin.zip`.
- URL permanente: `https://github.com/totokatz/borges.koplugin/releases/latest/download/borges.koplugin.zip`.
- Una sola carpeta raíz: `highlightsdetoto.koplugin/`, con `main.lua` y `_meta.lua` directamente adentro.
- El nombre interno se mantiene para conservar las rutas del actualizador y las instalaciones existentes.
- Se publica también `highlightsdetoto.koplugin-<versión>.zip` para los enlaces existentes. Ambos paquetes contienen los mismos bytes.
- Cada ZIP lleva un `.sha256` con su nombre correspondiente.
- No se incluyen pruebas, archivos ocultos ni configuraciones locales.

## Preparar una versión

1. Acordar la versión con el servidor de Borges. Los archivos del plugin deben coincidir con el manifiesto que sirve el actualizador; no editar una versión ya publicada.
2. Actualizar `highlightsdetoto.koplugin/plugin_version.lua` y `RELEASE_NOTES.md` dentro del plugin.
3. Ejecutar desde la raíz:

   ```sh
   python -m unittest discover -s scripts -p "test_*.py"
   python scripts/package.py --tag v<versión>
   ```

4. Revisar el contenido de `dist/` y probar la instalación en KOReader.
5. Crear y subir el tag `v<versión>`. GitHub Actions verifica la versión y publica los ZIP y sus checksums.

El empaquetador compara cada archivo del ZIP con el código fuente. Las pruebas también rechazan carpetas mal anidadas, archivos faltantes, cambios de contenido y configuraciones privadas.

## Releases existentes

No reemplazar archivos publicados: pueden estar referenciados por sus checksums. Para agregar el nombre amigable a una release anterior, copiar el ZIP original byte por byte como `borges.koplugin.zip` y generar un checksum que use ese nombre. No reconstruir el ZIP con otra herramienta.

Los archivos **Source code** son generados por GitHub y siempre aparecen en las releases. Las instrucciones de instalación deben apuntar al asset `borges.koplugin.zip`, no a esos archivos.
