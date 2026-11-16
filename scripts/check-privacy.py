#!/usr/bin/env python3
"""Fail on common privacy leaks without echoing the matched sensitive values."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import zipfile

PATTERNS = {
    "personal email": re.compile(rb"[A-Za-z0-9._%+-]{1,64}@(?:gmail|icloud|outlook|hotmail|qq|163|126)\.[A-Za-z.]+", re.I),
    "user home path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9][A-Za-z0-9_.-]*/"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "credential": re.compile(rb"(?:sk-(?:proj-|admin-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AKIA[A-Z0-9]{16})"),
    "JWT": re.compile(rb"eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}"),
}


def git(*args):
    return subprocess.check_output(["git", *args])


def inspect(data, label):
    categories = [name for name, pattern in PATTERNS.items() if pattern.search(data)]
    if categories:
        print(f"FAIL {label}: {', '.join(categories)}")
    return bool(categories)


def inspect_path(path):
    if path.is_symlink():
        return inspect(str(path.readlink()).encode(), str(path))
    if path.is_dir():
        return sum(inspect_path(child) for child in path.iterdir())
    if path.suffix.lower() == ".zip":
        with zipfile.ZipFile(path) as archive:
            return sum(inspect(archive.read(entry), f"{path.name}:{entry.filename}")
                       for entry in archive.infolist() if not entry.is_dir())
    return int(inspect(path.read_bytes(), str(path)))


def inspect_history():
    # Scan metadata as well as blobs: author/committer/tagger emails are not files.
    objects = {line.split(b" ", 1)[0] for line in git("rev-list", "--objects", "--all").splitlines()}
    objects.update(git("for-each-ref", "--format=%(objectname)", "refs/tags").splitlines())
    failed = 0
    process = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for oid in sorted(objects):
            process.stdin.write(oid + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3:
                raise RuntimeError("Cannot inspect Git object")
            size = int(header[2])
            data = process.stdout.read(size)
            process.stdout.read(1)
            failed += inspect(data, "Git " + header[1].decode() + " " + oid[:12].decode())
    finally:
        process.stdin.close()
        process.wait()
    return failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="Also inspect all local refs and tag metadata")
    parser.add_argument("paths", nargs="*", help="Files, directories or ZIPs; defaults to tracked working files")
    args = parser.parse_args()
    failed = 0
    if args.paths:
        failed += sum(inspect_path(Path(path)) for path in args.paths)
    else:
        for raw in git("ls-files", "-z").split(b"\0"):
            if raw:
                path = Path(raw.decode())
                if path.exists() or path.is_symlink():
                    failed += inspect_path(path)
    if args.history:
        failed += inspect_history()
    if failed:
        print(f"Privacy scan failed: {failed} affected objects/files. Values are redacted.")
        return 1
    print("Privacy scan passed (common patterns only; manual review is still required).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
