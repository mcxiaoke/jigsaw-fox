#!/usr/bin/env python3
"""Fix line endings (CRLF <-> LF) for a file or all text files in a directory.

Usage:
    python fix_line_endings.py <path> [--to lf|crlf] [--dry-run] [--ci] [--ext .py,.dart] [--exclude-dir NAME ...]

- Binary files are auto-detected and skipped.
- Default target ending is LF.
- --ci: check-only mode, no files are modified; exits with code 1 if any file
  does not match the target ending (for CI / git hooks).
"""

import argparse
import sys
from pathlib import Path

# Extensions treated as text; empty list means "check all files" (binary detection still applies).
DEFAULT_EXTS = None

BINARY_SNIFF_BYTES = 8192

# Common binary extensions to skip outright (fast path, avoids sniffing).
BINARY_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".ico", ".tiff",
    ".mp3", ".wav", ".ogg", ".flac", ".aac", ".m4a", ".mp4", ".avi", ".mov", ".mkv", ".webm",
    ".zip", ".7z", ".rar", ".gz", ".tar", ".bz2", ".xz",
    ".exe", ".dll", ".so", ".dylib", ".lib", ".a", ".obj", ".o",
    ".ttf", ".otf", ".woff", ".woff2", ".eot",
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    ".class", ".jar", ".pyc", ".pyd", ".wasm",
    ".db", ".sqlite", ".bin", ".dat", ".cache",
}


def is_binary_file(path: Path) -> bool:
    """Detect binary by NUL byte or a high ratio of non-text bytes in the first chunk."""
    try:
        with open(path, "rb") as f:
            chunk = f.read(BINARY_SNIFF_BYTES)
    except OSError:
        return True
    if not chunk:
        return False  # empty file -> treat as text
    if b"\x00" in chunk:
        return True
    # Non-ASCII bytes are fine (UTF-8 text), but heavy control chars indicate binary.
    control = sum(1 for b in chunk if b < 9 or (13 < b < 32))
    return control / len(chunk) > 0.10


def convert_bytes(data: bytes, target: str) -> tuple[bytes, int]:
    """Normalize all line endings to target. Returns (new_data, changed_line_count)."""
    # First unify everything to LF, then convert to target if needed.
    unified = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if target == "lf":
        return unified, data.count(b"\r")
    crlf = unified.replace(b"\n", b"\r\n")
    return crlf, unified.count(b"\n")


def fix_file(path: Path, target: str, dry_run: bool) -> tuple[bool, int]:
    """Returns (changed, line_count)."""
    data = path.read_bytes()
    new_data, count = convert_bytes(data, target)
    changed = new_data != data
    if changed and not dry_run:
        path.write_bytes(new_data)
    return changed, count


def iter_files(root: Path, exts: set[str] | None, exclude_dirs: set[str]):
    if root.is_file():
        yield root
        return
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if any(part in exclude_dirs for part in p.relative_to(root).parts[:-1]):
            continue
        if p.suffix.lower() in BINARY_EXTS:
            continue
        if exts is not None and p.suffix.lower() not in exts:
            continue
        yield p


def parse_ext_arg(value: str | None) -> set[str] | None:
    if not value:
        return DEFAULT_EXTS
    exts = set()
    for e in value.split(","):
        e = e.strip().lower()
        if not e:
            continue
        exts.add(e if e.startswith(".") else f".{e}")
    return exts


def main() -> int:
    parser = argparse.ArgumentParser(description="Fix line endings (LF/CRLF) for a file or directory.")
    parser.add_argument("path", type=Path, help="Input file or directory")
    parser.add_argument("--to", choices=["lf", "crlf"], default="lf", help="Target line ending (default: lf)")
    parser.add_argument("--dry-run", action="store_true", help="Only report what would change, do not modify files")
    parser.add_argument("--ci", action="store_true",
                        help="Check-only mode for CI / git hooks: never modify files, exit 1 if any file needs fixing")
    parser.add_argument("--ext", default="", help="Comma-separated extensions to process, e.g. .py,.dart (default: all non-binary)")
    parser.add_argument("--exclude-dir", nargs="*", default=[], help="Directory names to skip, e.g. build .git")
    args = parser.parse_args()

    root = args.path
    if not root.exists():
        print(f"Error: path does not exist: {root}", file=sys.stderr)
        return 2

    exts = parse_ext_arg(args.ext)
    exclude_dirs = set(args.exclude_dir) | {".git", "node_modules", "__pycache__"}
    ending = "LF" if args.to == "lf" else "CRLF"
    if args.ci:
        mode = "CI-CHECK"
        dry_run = True
    else:
        mode = "DRY-RUN" if args.dry_run else "FIX"
        dry_run = args.dry_run

    changed_count = 0
    checked = 0
    for f in iter_files(root, exts, exclude_dirs):
        if is_binary_file(f):
            continue
        checked += 1
        try:
            changed, count = fix_file(f, args.to, dry_run)
        except OSError as e:
            print(f"SKIP  {f} ({e})")
            continue
        if changed:
            changed_count += 1
            tag = "WOULD FIX" if dry_run else "FIXED"
            print(f"{tag}  {f}  ({count} line(s) -> {ending})")

    if args.ci:
        if changed_count:
            print(f"\n[CI-CHECK] target={ending}  checked={checked} text file(s), {changed_count} file(s) need fixing.")
            return 1
        print(f"\n[CI-CHECK] target={ending}  checked={checked} text file(s), all endings OK.")
        return 0

    action = "would be fixed" if dry_run else "fixed"
    print(f"\n[{mode}] target={ending}  checked={checked} text file(s), {changed_count} {action}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
