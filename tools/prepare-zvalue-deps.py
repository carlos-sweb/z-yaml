"""Expose z-value's local transitive dependencies inside Zig's package directory.

The pinned upstream manifest uses sibling paths. Only create aliases inside
z-yaml; never alter the downloaded package or the sibling repositories.
"""

from pathlib import Path


root = Path(__file__).resolve().parent.parent
names = (
    "z-array", "z-object", "z-regex", "z-string", "z-symbol", "z-map",
    "z-set", "z-error", "z-date", "z-promise", "z-bigint", "z-buffer",
    "z-temporal", "z-number", "z-equality",
)

for name in names:
    target = root.parent / name
    if not (target / "build.zig.zon").is_file():
        raise SystemExit(f"Missing sibling dependency: {target}")
    link = root / "zig-pkg" / name
    if link.is_symlink() or link.exists():
        if not link.is_symlink() or link.resolve() != target.resolve():
            raise SystemExit(f"Dependency alias already occupied: {link}")

(root / "zig-pkg").mkdir(exist_ok=True)
for name in names:
    link = root / "zig-pkg" / name
    if not link.is_symlink():
        link.symlink_to(root.parent / name, target_is_directory=True)

print(f"Prepared {len(names)} dependency aliases inside {root / 'zig-pkg'}")
