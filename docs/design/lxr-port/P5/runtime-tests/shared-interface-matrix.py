import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


frame, control, managed_input, output = map(Path, sys.argv[1:])
output.mkdir(exist_ok=False)
results = []


def run(name, major, minor, mode, expected, initialize, fast):
    env = os.environ.copy()
    env.pop("DOTNET_GCName", None)
    env["DOTNET_GCPath"] = str(control)
    env["SHARED_INTERFACE_MAJOR"] = str(major)
    env["SHARED_INTERFACE_MINOR"] = str(minor)
    env["SHARED_INTERFACE_CONTROL"] = mode
    command = [str(frame / "corerun"), str(managed_input), "--shared-barrier-behavior"]
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=30, check=False)
    text = result.stdout.decode("utf-8", errors="replace")
    (output / (name + ".log")).write_bytes(result.stdout)
    valid = (result.returncode > 0 and result.returncode != 124 and
             expected in text and "FAIL:" not in text and
             ("CONTROL initialize" in text) == initialize and
             ("CONTROL fast-functions" in text) == fast)
    valid = (valid and
             ("CONTROL enumeration-descriptor" in text) == (fast and minor >= 2) and
             ("CONTROL header-descriptor" in text) == (fast and minor >= 3))
    entry = dict(name=name, major=major, minor=minor, mode=mode,
                 command=command, expected_error=expected, exit_code=result.returncode, passed=valid)
    results.append(entry)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if not valid:
        raise RuntimeError(f"{name}: wrong rejection point or outcome\n{text}")
    print(f"PASS {name}: exact rejection point and error verified", flush=True)


for major in (5, 7):
    run(f"major-{major}", major, 8, "version-only",
        "GC interface layout is unsupported.", False, False)
for minor in (*range(2, 8), 9, 10, 4294967295):
    run(f"minor-{minor}", 6, minor, "version-only",
        "GC interface layout is unsupported.", False, False)
for minor in (0, 1, 8):
    run(f"known-minor-{minor}", 6, minor, "version-only",
        "CONTROL initialize", True, False)
for mode in ("missing-post", "missing-pre", "missing-heap", "missing-move",
             "missing-clear", "obsolete-range-only", "non-custom"):
    run(mode, 6, 8, mode,
        "GC old-value mode requires shared pre/post-store, heap-query, move and clear callbacks.", True, True)
run("unknown-flags", 6, 8, "unknown-flags",
    "GC supplied unsupported fast-function flags.", True, True)
run("old-protocol", 6, 1, "old-protocol",
    "GC old-value mode requires shared pre/post-store, heap-query, move and clear callbacks.", True, True)

identities = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in (control, managed_input, frame / "corerun", frame / "libcoreclr.so")}
(output / "identities.json").write_text(json.dumps(identities, indent=2) + "\n")
print(f"PASS all {len(results)} interface controls; no timeout, signal crash or earlier descriptor failure counted")
