import hashlib
import io
import json
from pathlib import Path
import re
import tarfile
import tempfile
import unittest

from linker_inputs_common import ROOT, digest_bytes, json_bytes, read_archive, write_archive
from build_linker_inputs import MSVC_RUNTIME, MSVC_RUNTIME_SOURCES, WINDOWS_FILES, WINDOWS_RUNTIME, macos_stub
from linker_inputs import attest_args


class LinkerInputTests(unittest.TestCase):
    def fixture(self, root: Path) -> Path:
        payload = {"targets/x64mac/libSystem.tbd": b"stub"}
        manifest = {"schema": 1, "version": "1.0.0", "source_commit": "a" * 40,
                    "input_fingerprint": "b" * 64,
                    "files": {name: {"sha256": digest_bytes(data), "size": len(data)} for name, data in payload.items()}}
        payload["dependency.json"] = json_bytes(manifest)
        archive = root / "inputs.tar.gz"
        write_archive(archive, payload)
        return archive

    def test_round_trip_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = self.fixture(root)
            copy = root / "copy.tar.gz"
            _, files = read_archive(first)
            write_archive(copy, files)
            self.assertEqual(first.read_bytes(), copy.read_bytes())

    def test_rejects_unsafe_duplicate_and_tampered_members(self):
        for name in ("../escape", "/absolute", "C:/escape", "a\\b"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "bad.tar.gz"
                with tarfile.open(archive, "w:gz") as tar:
                    info = tarfile.TarInfo(name)
                    tar.addfile(info, io.BytesIO())
                with self.assertRaises(ValueError):
                    read_archive(archive)
        with tempfile.TemporaryDirectory() as temporary:
            archive = self.fixture(Path(temporary))
            manifest, files = read_archive(archive)
            files["targets/x64mac/libSystem.tbd"] = b"tampered"
            bad = Path(temporary) / "tampered.tar.gz"
            write_archive(bad, files)
            with self.assertRaisesRegex(ValueError, "integrity"):
                read_archive(bad)

    def test_macos_stub_is_project_generated_dual_arch_tapi_v4(self):
        stub, catalog, provenance = macos_stub()
        self.assertIn(b"tbd-version:     4", stub)
        self.assertIn(b"x86_64-macos, arm64-macos", stub)
        self.assertIn(b"project-authored", provenance)
        self.assertEqual(json.loads(catalog)["install_name"], "/usr/lib/libSystem.B.dylib")

    def test_windows_header_lists_exactly_the_released_inputs_after_the_app(self):
        header = (ROOT / "platform/main.roc").read_text()
        listed = re.search(r"x64win: \{ inputs: \[(.*?)\] \}", header, re.DOTALL).group(1)
        inputs = [item.strip().strip('"') for item in listed.split(",") if item.strip()]
        # The host is loaded whole and comes first; what follows the app is searched as needed.
        self.assertEqual(inputs[:3], ["host.lib", "app", WINDOWS_RUNTIME])
        self.assertEqual(sorted(inputs[2:]), sorted(WINDOWS_FILES))

    def test_vendored_msvc_runtime_matches_its_recorded_upstream(self):
        upstream = json.loads((MSVC_RUNTIME / "UPSTREAM.json").read_text())
        self.assertRegex(upstream["commit"], r"^[0-9a-f]{40}$")
        self.assertEqual(sorted(upstream["files"]), sorted(MSVC_RUNTIME_SOURCES))
        for name, sha256 in upstream["files"].items():
            self.assertEqual(hashlib.sha256((MSVC_RUNTIME / name).read_bytes()).hexdigest(), sha256)
        notice = upstream["license_file"]
        self.assertEqual(hashlib.sha256((MSVC_RUNTIME / notice["vendored_as"]).read_bytes()).hexdigest(), notice["sha256"])

    def test_online_attestation_is_bound_to_reusable_signer(self):
        lock = {"repository": "owner/platform", "signer_repository": "owner/automation",
                "workflow": "owner/automation/.github/workflows/publish-linker-inputs.yml",
                "source_commit": "a" * 40, "signer_commit": "b" * 40,
                "source_ref": "refs/heads/main"}
        args = attest_args(Path("archive.tar.gz"), lock)
        self.assertNotIn("--bundle", args)
        self.assertEqual(args[args.index("--repo") + 1], "owner/platform")
        self.assertNotIn("--signer-repo", args)
        self.assertEqual(args[args.index("--signer-workflow") + 1], lock["workflow"])
        self.assertEqual(args[args.index("--signer-digest") + 1], lock["signer_commit"])
        self.assertEqual(args[args.index("--predicate-type") + 1], "https://slsa.dev/provenance/v1")


if __name__ == "__main__":
    unittest.main()
