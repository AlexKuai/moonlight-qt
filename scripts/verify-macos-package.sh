#!/bin/bash
# Inspect the actual disk image, not just the pre-packaging app bundle.
set -euo pipefail

image_path=$1
hdiutil verify "$image_path"
mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/moonlight-verify.XXXXXX")
mounted=0
cleanup() {
    if [ "$mounted" = 1 ]; then
        hdiutil detach "$mount_dir" >/dev/null || true
    fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach "$image_path" -readonly -nobrowse -mountpoint "$mount_dir"
mounted=1
app_path="$mount_dir/Moonlight.app"
binary_path="$app_path/Contents/MacOS/Moonlight"
test -f "$binary_path"

codesign --verify --deep --strict "$app_path"
codesign -dv "$app_path" 2>&1
lipo "$binary_path" -verify_arch arm64 x86_64
echo "Main executable architectures: $(lipo -archs "$binary_path")"
echo "Application version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
echo "Minimum system: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")"

# Every bundled Mach-O must support native execution on Apple Silicon.
# Reject build-machine paths in linked libraries; system and bundle-relative
# paths are valid. Runtime loading is also checked by the version probe below.
python3 - "$app_path" <<'PY'
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
executable_dir = root / 'Contents/MacOS'
system_roots = ('/System/Library/', '/usr/lib/')

def run_paths(path):
    commands = subprocess.check_output(['otool', '-arch', 'arm64', '-l', str(path)], text=True)
    return re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', commands)

def expand(path, loader):
    return pathlib.Path(path.replace('@loader_path', str(loader.parent))
                       .replace('@executable_path', str(executable_dir))).resolve()

def in_bundle(path):
    return path == root or root in path.parents

main_paths = run_paths(executable_dir / 'Moonlight')
magic_values = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
count = 0
errors = []
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    with path.open('rb') as binary:
        if binary.read(4) not in magic_values:
            continue
    if subprocess.run(['lipo', str(path), '-verify_arch', 'arm64']).returncode != 0:
        errors.append(f'Missing arm64 architecture: {path}')
        continue
    local_paths = run_paths(path)
    for entry in local_paths:
        if not entry.startswith(system_roots) and not in_bundle(expand(entry, path)):
            errors.append(f'Non-portable run path: {path}: {entry}')
    search_paths = [expand(entry, path) for entry in local_paths]
    search_paths += [expand(entry, executable_dir / 'Moonlight') for entry in main_paths]
    linked = subprocess.check_output(['otool', '-arch', 'arm64', '-L', str(path)], text=True)
    for line in linked.splitlines():
        if not line.startswith('\t'):
            continue
        dependency = line.strip().split(' (compatibility version', 1)[0]
        if dependency.startswith(system_roots):
            continue
        if dependency.startswith('@rpath/'):
            candidates = [base / dependency[len('@rpath/'):] for base in search_paths]
        elif dependency.startswith(('@loader_path/', '@executable_path/')):
            candidates = [expand(dependency, path)]
        else:
            errors.append(f'Non-portable dependency: {path}: {dependency}')
            continue
        if not any(in_bundle(candidate.resolve()) and candidate.is_file() for candidate in candidates):
            errors.append(f'Dependency not found in bundle: {path}: {dependency}')
    count += 1
if count == 0:
    raise SystemExit('No Mach-O files were inspected')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Apple Silicon architecture and dependency checks passed for {count} Mach-O files')
PY

expected_version=$(tr -d '\r\n' < app/version.txt)
version_output=$(arch -arm64 "$binary_path" --version 2>&1)
printf '%s\n' "$version_output"
[[ "$version_output" == *"Moonlight $expected_version"* ]]
shasum -a 256 "$image_path"
echo "macOS package verification passed"
