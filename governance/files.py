"""Private staging, atomic receipts and cross-process management locks."""
import json
import os
import shutil
import tempfile
from contextlib import contextmanager
from pathlib import Path

from .contracts import GovernanceError, canonical, require


def private_dir(path):
    path = Path(path)
    for entry in (path, *path.absolute().parents):
        try: info = entry.lstat()
        except FileNotFoundError: continue
        linked = entry.is_symlink() or getattr(entry, "is_junction", lambda: False)() or bool(getattr(info, "st_file_attributes", 0) & 0x400)
        # macOS has OS-owned /var -> /private/var; user-controlled links remain forbidden.
        trusted_os_link = os.name != "nt" and entry != path and info.st_uid == 0
        require(not linked or trusted_os_link, "unsafe_state_directory")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == "nt":
        from .windows_acl import protect
        protect(path)
        # Existing child files can have explicit broad ACEs and Windows bypass-traverse privilege.
        # Protect their actual DACLs as well; parent protection alone is insufficient.
    else:
        os.chmod(path, 0o700)
        require(path.stat().st_uid == os.getuid(), "unsafe_state_owner")
    for child in path.rglob("*"):
        info = child.lstat()
        require(not child.is_symlink() and not getattr(child, "is_junction", lambda: False)()
                and not (getattr(info, "st_file_attributes", 0) & 0x400), "unsafe_state_directory")
        if child.is_file(): require(info.st_nlink == 1, "unsafe_state_file")
        if os.name == "nt": protect(child)
        else: require(info.st_uid == os.getuid(), "unsafe_state_owner")
    return path


def atomic_json(path, value):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix="receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(canonical(value)); handle.flush(); os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name): os.unlink(name)


@contextmanager
def file_lock(path):
    handle = open(path, "a+b")
    try:
        handle.seek(0); handle.write(b"0"); handle.flush(); handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise GovernanceError("import_busy") from None
        yield
    finally:
        handle.close()  # Closing releases OS locks even after process failure.


@contextmanager
def stage_bundle(value, source, state):
    from .contracts import verify_bundle
    verify_bundle(value, source)
    with tempfile.TemporaryDirectory(prefix="stage-", dir=state) as tmp:
        root = private_dir(tmp)
        for file in value["files"]:
            dest = root / file["path"]
            dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            # Destination is private and newly created; verify the copied bytes before any runtime action.
            with open(Path(source) / file["path"], "rb") as src, dest.open("xb") as out:
                shutil.copyfileobj(src, out, length=1024 * 1024)
            os.chmod(dest, 0o400)
        verify_bundle(value, root)
        try:
            yield root
        finally:
            for dest in root.rglob("*"):
                if dest.is_file(): os.chmod(dest, 0o600)
