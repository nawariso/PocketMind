"""Private state must remove explicit broad ACLs and refuse reparse ancestors."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from governance.files import private_dir
from governance.contracts import GovernanceError


class FileTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows ACL regression")
    def test_explicit_everyone_write_is_removed_from_existing_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shared"; path.mkdir()
            result = subprocess.run(["icacls", str(path), "/grant", "*S-1-1-0:(OI)(CI)M"], capture_output=True)
            self.assertEqual(result.returncode, 0)
            child = path / "jobs.db"; child.write_text("sensitive state")
            result = subprocess.run(["icacls", str(child), "/grant", "*S-1-1-0:M"], capture_output=True)
            self.assertEqual(result.returncode, 0)
            private_dir(path)
            saved = Path(tmp) / "acl.txt"
            result = subprocess.run(["icacls", str(path), "/save", str(saved)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn(";;;WD)", saved.read_text("utf-16-le"))
            child_acl = Path(tmp) / "child-acl.txt"
            result = subprocess.run(["icacls", str(child), "/save", str(child_acl)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            self.assertNotIn(";;;WD)", child_acl.read_text("utf-16-le"))

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_symlink_ancestor_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); (root / "real").mkdir(); (root / "link").symlink_to(root / "real", target_is_directory=True)
            with self.assertRaises(GovernanceError): private_dir(root / "link" / "state")


if __name__ == "__main__": unittest.main()
