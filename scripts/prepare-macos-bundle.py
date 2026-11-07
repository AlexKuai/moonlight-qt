"""Remove development-only library search paths before signing the app."""
import pathlib
import re
import shutil
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
executable_dir = root / "Contents/MacOS"
# Moonlight does not use QtSql or QtQuick.LocalStorage. macdeployqt may copy
# optional SQL drivers whose third-party database clients are not distributable
# with this app. Match the Windows deployment's --no-sql policy.
sql_plugins = root / "Contents/PlugIns/sqldrivers"
if sql_plugins.exists():
    if sql_plugins.is_symlink() or root not in sql_plugins.resolve().parents:
        raise SystemExit("SQL plugin directory is outside the application bundle")
    shutil.rmtree(sql_plugins)
    print("Removed unused Qt SQL driver plugins")

magic_values = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
removed = 0
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open("rb") as binary:
        if binary.read(4) not in magic_values:
            continue
    commands = subprocess.check_output(["otool", "-l", str(path)], text=True)
    run_paths = set(re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", commands))
    for entry in sorted(run_paths):
        if entry.startswith(("/System/Library/", "/usr/lib/")):
            continue
        resolved = pathlib.Path(entry.replace("@loader_path", str(path.parent))
                                .replace("@executable_path", str(executable_dir))).resolve()
        if resolved == root or root in resolved.parents:
            continue
        subprocess.run(["install_name_tool", "-delete_rpath", entry, str(path)], check=True)
        print(f"Removed external run path: {path.relative_to(root)}: {entry}")
        removed += 1
print(f"Removed {removed} external run paths before code signing")
