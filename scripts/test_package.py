import hashlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from package import ROOT, PLUGIN, build, verify


class PackageTests(unittest.TestCase):
    def test_installable_repeatable_and_compatible(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            archive = build(ROOT / PLUGIN, out)
            first = archive.read_bytes()
            self.assertEqual(first, build(ROOT / PLUGIN, out).read_bytes())
            self.assertGreater(verify(archive, ROOT / PLUGIN), 4)
            self.assertEqual(first, next(out.glob(f"{PLUGIN}-*.zip")).read_bytes())
            self.assertEqual(hashlib.sha256(first).hexdigest(),
                             (out / "borges.koplugin.zip.sha256").read_text().split()[0])

    def test_rejects_wrong_tag(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                build(ROOT / PLUGIN, Path(temp), "v0.0.0-wrong")

    def test_rejects_missing_nested_private_and_changed_files(self):
        with tempfile.TemporaryDirectory() as temp:
            archive = build(ROOT / PLUGIN, Path(temp))
            with zipfile.ZipFile(archive) as z:
                originals = {n: z.read(n) for n in z.namelist()}
            variants = [
                {n: b for n, b in originals.items() if not n.endswith("/main.lua")},
                {"extra/" + n: b for n, b in originals.items()},
                {**originals, f"{PLUGIN}/web_config.json": b"{}"},
                {**originals, f"{PLUGIN}/../escape.lua": b"return {}"},
                {**originals, f"{PLUGIN}/main.lua": b"return {}"},
            ]
            for index, files in enumerate(variants):
                with self.subTest(variant=index):
                    bad = Path(temp) / "bad.zip"
                    with zipfile.ZipFile(bad, "w") as z:
                        for name, content in files.items():
                            z.writestr(name, content)
                    with self.assertRaises(ValueError):
                        verify(bad, ROOT / PLUGIN)


if __name__ == "__main__":
    unittest.main()
