"""Deterministic tests for public/private JSON Schema client boundaries."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from client_contract_boundary import (  # noqa: E402
    boundary_errors,
    client_directory_names,
    missing_core_targets,
    private_leak_canary,
)

SURFACE_PATH = ROOT / "clients" / "api-surface.json"
CLIENTS_ROOT = ROOT / "clients"


class ClientContractBoundaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.surface = json.loads(SURFACE_PATH.read_text(encoding="utf-8"))

    def test_committed_public_surface_does_not_expose_private_symbols(self) -> None:
        self.assertEqual((), boundary_errors(self.surface))

    def test_private_reference_negative_canary_is_rejected(self) -> None:
        mutant = private_leak_canary(self.surface)
        self.assertTrue(boundary_errors(mutant))

    def test_polyglot_floor_and_core_runtimes(self) -> None:
        names = client_directory_names(
            tuple(
                path.name
                for path in CLIENTS_ROOT.iterdir()
                if path.is_dir()
            )
        )
        self.assertGreaterEqual(len(names), 15, names)
        self.assertEqual((), missing_core_targets(names), names)


if __name__ == "__main__":
    unittest.main()
