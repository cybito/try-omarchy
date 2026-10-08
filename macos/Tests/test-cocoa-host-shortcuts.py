#!/usr/bin/env python3
"""Exercise host shortcut routing with real CGEvents and the production tap."""
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-cocoa-host-shortcuts.patch'


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class HostShortcutTests(unittest.TestCase):
    @unittest.skipUnless(platform.system() == 'Darwin', 'requires Cocoa events')
    def test_press_ownership_and_host_modifier_release(self):
        source = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                           if line.startswith(('+', ' ')) and not line.startswith('+++'))
        helpers = source[source.index('static NSEventModifierFlags host_shortcut_modifiers;'):
                         source.index('static CGEventRef handleTapEvent(')]
        # Compile the real physical-key and modifier consumer; leave mouse,
        # scroll, and injected-text behavior outside this keyboard contract.
        start = source.index('- (bool) handleEventLocked:(NSEvent *)event\n{')
        end = source.index('        case NSEventTypeMagnify:', start)
        method = source[start:end] + '        default: return false;\n    }\n}\n'
        harness = (ROOT / 'macos/Tests/cocoa-host-shortcuts-harness.m').read_text()
        harness = harness.replace('/* HELPERS */', helpers)
        harness = harness.replace('/* TAP */', block(source, 'static CGEventRef handleTapEvent('))
        harness = harness.replace('/* METHOD */', method)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'test.m').write_text(harness)
            subprocess.run(['xcrun', 'clang', '-Werror', '-framework', 'Cocoa',
                            '-framework', 'Carbon', str(path / 'test.m'), '-o',
                            str(path / 'test')], check=True)
            subprocess.run([str(path / 'test')], check=True)


if __name__ == '__main__':
    unittest.main()
