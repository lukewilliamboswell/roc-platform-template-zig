import json
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

import runtime
from runtime_common import digest, runtime_members, write_json


class ConsumerTests(unittest.TestCase):
    def fixture(self, root):
        tree = root / "tree"
        files = runtime_members() - {"manifest.json"}
        for name in files:
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"runtime fixture")
        manifest = {"schema": 1, "source_commit": "a" * 40, "version": "1.0.0",
                    "files": {name: digest(tree / name) for name in files}}
        write_json(tree / "manifest.json", manifest)
        write_json(root / "runtime.spdx.json", {"fixture": True})
        with tarfile.open(root / "archive.tar.gz", "w:gz") as archive:
            for name in sorted(runtime_members()):
                archive.add(tree / name, arcname=name)
        return {"sha256": digest(root / "archive.tar.gz"), "sbom_sha256": digest(root / "runtime.spdx.json"),
                "source_commit": "a" * 40, "tag": "runtime-1.0.0"}

    def test_offline_check_never_uses_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lock = self.fixture(root)
            with patch("runtime.cache_path", return_value=root), patch("runtime.urllib.request.urlretrieve", side_effect=AssertionError("network")):
                self.assertEqual(runtime.check(lock)[0], root / "tree")

    def test_manifest_cannot_redefine_cached_file_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lock = self.fixture(root)
            path = root / "tree/targets/x64musl/libc.a"
            path.write_bytes(b"replacement")
            manifest_path = root / "tree/manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["files"]["targets/x64musl/libc.a"] = digest(path)
            write_json(manifest_path, manifest)
            with patch("runtime.cache_path", return_value=root):
                with self.assertRaisesRegex(ValueError, "manifest differs"):
                    runtime.check(lock)

    def test_modified_archive_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lock = self.fixture(root)
            (root / "archive.tar.gz").write_bytes(b"tampered")
            with patch("runtime.cache_path", return_value=root):
                with self.assertRaisesRegex(ValueError, "archive checksum mismatch"):
                    runtime.check(lock)

    def test_verification_binds_signer_source_and_predicate(self):
        lock = {"repository": "owner/repo", "workflow": ".github/workflows/runtime.yml",
                "source_commit": "a" * 40, "source_ref": "refs/heads/main"}
        args = runtime.verification_args(Path("archive"), Path("signature"), lock, runtime.SPDX)
        for option, value in [("--repo", "owner/repo"), ("--signer-workflow", "owner/repo/.github/workflows/runtime.yml"),
                              ("--source-digest", "a" * 40), ("--signer-digest", "a" * 40),
                              ("--source-ref", "refs/heads/main"), ("--predicate-type", runtime.SPDX)]:
            self.assertEqual(args[args.index(option) + 1], value)
        self.assertIn("--deny-self-hosted-runners", args)

    def test_invalid_signature_does_not_fall_back(self):
        lock = {"repository": "owner/repo", "workflow": ".github/workflows/runtime.yml",
                "source_commit": "a" * 40, "source_ref": "refs/heads/main"}
        with patch("runtime.subprocess.check_output", side_effect=subprocess.CalledProcessError(1, "gh")):
            with self.assertRaises(subprocess.CalledProcessError):
                runtime.verify_attestations(Path("unused"), lock)

    def test_sbom_must_match_signed_predicate(self):
        lock = {"repository": "owner/repo", "workflow": ".github/workflows/runtime.yml",
                "source_commit": "a" * 40, "source_ref": "refs/heads/main"}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "runtime.spdx.json").write_text('{"changed": true}')
            response = json.dumps([{"verificationResult": {"statement": {"predicate": {"signed": True}}}}])
            with patch("runtime.subprocess.check_output", return_value=response):
                with self.assertRaisesRegex(ValueError, "differs"):
                    runtime.verify_attestations(root, lock)

    def test_missing_cache_has_actionable_error_without_network(self):
        with tempfile.TemporaryDirectory() as temp, patch("runtime.cache_path", return_value=Path(temp)):
            with self.assertRaisesRegex(ValueError, "runtime.py fetch"):
                runtime.check({"sha256": "a" * 64})


if __name__ == "__main__":
    unittest.main()
