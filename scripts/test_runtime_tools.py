import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from build_runtime import link_inputs
from runtime_common import digest, runtime_members, safe_extract, validate_tree, write_json


class RuntimeTests(unittest.TestCase):
    def test_tar_rejects_unsafe_and_incomplete_inputs(self):
        for name, kind in [("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("C:/escape", tarfile.REGTYPE), ("targets/link", tarfile.SYMTYPE),
                           ("targets/hard", tarfile.LNKTYPE), ("unexpected", tarfile.REGTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                archive = root / "test.tar"
                with tarfile.open(archive, "w") as tar:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    info.linkname = "elsewhere" if kind != tarfile.REGTYPE else ""
                    tar.addfile(info, io.BytesIO())
                with self.assertRaises(ValueError):
                    safe_extract(archive, root / "out", expected=runtime_members())
                self.assertFalse((root / "out").exists())

    def test_duplicate_archive_member(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "duplicate.tar"
            with tarfile.open(archive, "w") as tar:
                for _ in range(2):
                    tar.addfile(tarfile.TarInfo("manifest.json"), io.BytesIO())
            with self.assertRaises(ValueError):
                safe_extract(archive, root / "out")

    def test_cached_file_integrity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            files = runtime_members() - {"manifest.json"}
            for name in files:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
            manifest = {"schema": 1, "files": {name: digest(root / name) for name in files}}
            write_json(root / "manifest.json", manifest)
            self.assertEqual(validate_tree(root), manifest)
            (root / "targets/x64musl/libc.a").write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                validate_tree(root)

    def test_linker_inputs_cannot_escape_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                link_inputs("ld.lld -o probe /etc/libc.a", root / "cache")
            with self.assertRaises(ValueError):
                link_inputs("ld.lld -o probe cache/libunknown.a", root / "cache")


if __name__ == "__main__":
    unittest.main()
