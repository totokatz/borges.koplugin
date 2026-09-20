# Publishing Borges

1. Update `borges.koplugin/plugin_version.lua` and the release notes.
2. Run `python -m unittest discover -s scripts -p 'test_*.py'`.
3. Run `python scripts/package.py --tag v<VERSION>`.
4. Check that `dist/borges.koplugin.zip` contains one root folder, `borges.koplugin/`, with `main.lua` and `_meta.lua` directly inside it.
5. Commit and push the matching version tag. The release workflow publishes the installable ZIP and SHA-256 checksums.

Published versions are immutable. Use a new version for changes. Private configuration files and test fixtures are excluded from the package.
