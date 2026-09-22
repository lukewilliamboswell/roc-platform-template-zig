import json
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

import runtime
import build_input_release
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

    def test_content_cache_hit_is_rehashed_without_network(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            lock = self.fixture(root) | {"content": True}
            lock["size"] = (root / "archive.tar.gz").stat().st_size
            with patch("runtime.load_lock", return_value=lock), \
                 patch("runtime.cache_path", return_value=root), \
                 patch("runtime.urllib.request.urlretrieve", side_effect=AssertionError("network")):
                runtime.fetch()

    def test_corrupt_content_cache_is_replaced_from_locked_url(self):
        with tempfile.TemporaryDirectory() as temp, tempfile.TemporaryDirectory() as source_temp:
            root, source = Path(temp), Path(source_temp)
            lock = self.fixture(source) | {"content": True, "url": "https://example.invalid/link-inputs-all.tar"}
            lock["size"] = (source / "archive.tar.gz").stat().st_size
            root.mkdir(exist_ok=True)
            (root / "archive.tar.gz").write_bytes(b"corrupt")
            def download(url, destination):
                self.assertEqual(url, lock["url"])
                Path(destination).write_bytes((source / "archive.tar.gz").read_bytes())
            with patch("runtime.load_lock", return_value=lock), \
                 patch("runtime.cache_path", return_value=root), \
                 patch("runtime.urllib.request.urlretrieve", side_effect=download) as retrieve:
                runtime.fetch()
            retrieve.assert_called_once()
            self.assertEqual(digest(root / "archive.tar.gz"), lock["sha256"])

    def test_publication_archive_is_uncompressed_deterministic_tar_with_exact_manifest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            built, output = root / "built", root / "release"
            built.mkdir()
            fixture = root / "fixture"
            fixture.mkdir()
            self.fixture(fixture)
            (built / "roc-runtime-1.0.0.tar.gz").write_bytes((fixture / "archive.tar.gz").read_bytes())
            environment = {"GITHUB_REPOSITORY": "lukewilliamboswell/roc-platform-template-zig",
                           "GITHUB_SHA": "a" * 40, "GITHUB_REF": "refs/heads/change-runtime"}
            with patch.dict(os.environ, environment, clear=True), \
                 patch("build_input_release.input_fingerprint", return_value="f" * 64):
                build_input_release.prepare(built, output)
            asset = output / "link-inputs-all.tar"
            self.assertNotEqual(asset.read_bytes()[:2], b"\x1f\x8b")
            with tarfile.open(asset, "r:") as archive:
                self.assertEqual({member.name for member in archive}, runtime_members())
                self.assertTrue(all(member.isfile() and member.mtime == 0 and member.mode == 0o644
                                    for member in archive.getmembers()))
            manifest = json.loads((output / "build-input-release.json").read_text())
            self.assertEqual(set(manifest), {"schema_version", "kind", "source", "assets"})
            self.assertEqual(manifest["assets"]["all"], {
                "asset": asset.name, "sha256": digest(asset), "size": asset.stat().st_size})


if __name__ == "__main__":
    unittest.main()
