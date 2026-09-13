"""Regression tests for generate_dart.py output-path reporting.

The pub.dev dry-run intentionally generates into a temporary directory. That
must not couple generation to the repository root or leak the temporary parent
path into logs.
"""

from pathlib import Path
import tempfile
import unittest

import generate_dart as gd


class DartGeneratorOutputPathRegression(unittest.TestCase):
    def test_repository_output_is_rendered_relative_to_root(self):
        output = gd.ROOT / "clients" / "dart" / "generated" / "fixture.dart"
        self.assertEqual(
            gd.display_output_path(output),
            "clients/dart/generated/fixture.dart",
        )

    def test_external_dry_run_output_is_supported_without_parent_path_leak(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "fiducia_client.dart"
            label = gd.display_output_path(output)
            self.assertEqual(label, "<external>/fiducia_client.dart")
            self.assertNotIn(directory, label)


if __name__ == "__main__":
    unittest.main()
