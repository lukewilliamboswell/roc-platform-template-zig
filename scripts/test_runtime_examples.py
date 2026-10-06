import tempfile
import unittest
from pathlib import Path

from examples_archive import rewrite_header, rewrite_tree

HEADER = 'app [main!] { roc: "nightly-1", pf: platform "../../platform/main.roc" }\n\nmain! = 1\n'


class ExamplesArchiveTests(unittest.TestCase):
    def test_platform_rewrite_keeps_compiler(self):
        out = rewrite_header(HEADER, platform="https://example.test/b.tar.zst")
        self.assertIn('roc: "nightly-1"', out)
        self.assertIn('platform "https://example.test/b.tar.zst"', out)

    def test_compiler_rewrite_keeps_platform(self):
        out = rewrite_header(HEADER, compiler="nightly-2")
        self.assertIn('roc: "nightly-2"', out)
        self.assertIn('platform "../../platform/main.roc"', out)

    def test_missing_header_fields_fail(self):
        with self.assertRaises(SystemExit):
            rewrite_header("main! = 1\n", platform="x")

    def test_empty_tree_fails(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(SystemExit):
            rewrite_tree(Path(tmp), compiler="nightly-2")


if __name__ == "__main__":
    unittest.main()
