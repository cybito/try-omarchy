#!/usr/bin/env python3
"""Exercise DMG packaging's host-tool boundary without opening Finder in CI."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PackageDMGTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="package-dmg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Try Omarchy.app"
        self.app.mkdir()
        self.log = self.root / "commands.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake-tool"
        fake.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, shutil, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["DMG_TEST_LOG"], "a") as log:
    log.write(json.dumps([tool, *args]) + "\\n")
if tool == "ditto":
    shutil.copytree(args[0], args[1])
elif tool == "hdiutil" and args[0] == "create":
    pathlib.Path(args[-1]).touch()
elif tool == "hdiutil" and args[0] == "convert":
    pathlib.Path(args[args.index("-o") + 1]).touch()
elif tool == "osascript" and os.environ.get("DMG_TEST_FAIL_LAYOUT"):
    sys.exit(1)
''')
        fake.chmod(0o755)
        for tool in ("codesign", "diskutil", "ditto", "hdiutil", "osascript", "sync"):
            (self.bin / tool).symlink_to(fake)

    def package(self, name, *, fail_layout=False):
        environment = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                           DMG_TEST_LOG=str(self.log))
        if fail_layout:
            environment["DMG_TEST_FAIL_LAYOUT"] = "1"
        return subprocess.run(
            ["bash", str(ROOT / "macos/package-dmg.sh"),
             str(self.app), str(self.root / name)],
            env=environment, capture_output=True, text=True,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_working_volumes_are_unique_and_final_installer_name_is_restored(self):
        labels = []
        for name in ("first.dmg", "second.dmg"):
            with self.subTest(name=name):
                self.log.unlink(missing_ok=True)
                result = self.package(name)
                self.assertEqual(result.returncode, 0, result.stderr)
                commands = self.commands()
                create = next(c for c in commands if c[:2] == ["hdiutil", "create"])
                labels.append(create[create.index("-volname") + 1])
                self.assertNotEqual(labels[-1], "Try Omarchy")
                attach = next(c for c in commands if c[:2] == ["hdiutil", "attach"])
                mount = attach[attach.index("-mountpoint") + 1]
                self.assertEqual(Path(mount).name, labels[-1])
                layout = next(c for c in commands if c[0] == "osascript")
                rename = ["diskutil", "rename", mount, "Try Omarchy"]
                self.assertEqual(layout[2:], [mount, self.app.name])
                self.assertLess(commands.index(layout), commands.index(rename))
                self.assertLess(commands.index(rename),
                                commands.index(["hdiutil", "detach", mount]))
                self.assertTrue((self.root / name).is_file())
                self.assertFalse(Path(mount).parent.exists())
        self.assertNotEqual(*labels)

    def test_failed_layout_detaches_without_converting_or_renaming(self):
        result = self.package("failed.dmg", fail_layout=True)
        self.assertNotEqual(result.returncode, 0)
        commands = self.commands()
        layout = next(c for c in commands if c[0] == "osascript")
        mount = layout[2]
        self.assertIn(["hdiutil", "detach", mount, "-force"], commands)
        self.assertFalse(any(c[0] == "diskutil" for c in commands))
        self.assertFalse(any(c[:2] == ["hdiutil", "convert"] for c in commands))
        self.assertFalse((self.root / "failed.dmg").exists())
        self.assertFalse(Path(mount).parent.exists())


if __name__ == "__main__":
    unittest.main()
