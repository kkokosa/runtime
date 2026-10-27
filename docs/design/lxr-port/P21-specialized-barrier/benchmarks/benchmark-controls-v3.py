import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

repo, evidence = map(Path, sys.argv[1:3])
phase = sys.argv[3]
project = evidence / "barrier-benchmarks"
driver = project / "bin/Release/net11.0/BarrierBenchmarks.dll"
input_version = 4 if phase.endswith("-v4") else 3
pin = evidence / ("benchmark-qualification-input-v" + str(input_version))
fixture = pin / "bin/Release/net11.0/BarrierBenchmarks.dll" if phase == "controls-v4" else driver
output = evidence / ("benchmark-v3-" + phase)
output.mkdir(exist_ok=True)
if any(output.iterdir()):
    raise RuntimeError("Refusing to overwrite retained benchmark records: " + str(output))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


for relative in ("Program.cs", "BarrierBenchmarks.csproj"):
    if sha(project / relative) != sha(pin / relative):
        raise RuntimeError("The benchmark source/binary changed after pinning: " + relative)
if sha(driver) != sha(evidence / "benchmark-qualification-input-v3/bin/Release/net11.0/BarrierBenchmarks.dll"):
    raise RuntimeError("The benchmark driver changed after its v3 source build.")
frames = {}
for revision, root, manifest in (
    ("baseline", "testhost_baseline", "baseline-linux-release-frame.json"),
    ("changed", "testhost_shared_linux_release_v2", "changed-linux-release-v2-frame.json"),
):
    hosts = [path for path in (repo / "artifacts/bin" / root).rglob("corerun")
             if path.parent.name == "12.0.0"]
    if len(hosts) != 1:
        raise RuntimeError("Expected one preserved corerun in " + root)
    frame = hosts[0].parent
    for entry in json.loads((evidence / manifest).read_text())["files"]:
        path = frame / entry.get("name", entry.get("file"))
        if sha(path).lower() != entry.get("sha256", entry.get("hash")).lower():
            raise RuntimeError("A preserved frame hash changed: " + str(path))
    frames[revision] = frame, evidence / manifest
records = []


def environment(revision, kind, diagnostics=False):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("DOTNET_", "COMPlus_", "BARRIER_")):
            del env[key]
    env.update(BARRIER_COLLECTOR=kind, BARRIER_FRAME_MANIFEST=str(frames[revision][1]),
               DOTNET_LXRSharedBarrierMetrics="1" if diagnostics else "0",
               DOTNET_LXREvacuateNursery="0", DOTNET_LXREvacuateMature="0",
               DOTNET_TieredCompilation="0", DOTNET_gcServer="1" if kind == "Server" else "0")
    if kind == "LXR":
        env["DOTNET_GCName"] = "libclrlxrgc.so"
    return env


def execute(name, command, env, required, timeout=600, qualify_child=False):
    with (output / (name + ".log")).open("wb") as log:
        result = subprocess.run(command, cwd=project, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    text = (output / (name + ".log")).read_text(errors="replace")
    passed = result.returncode == 0 and all(marker in text for marker in required)
    records.append(dict(name=name, command=command, cwd=str(project),
                        environment={key: value for key, value in env.items()
                                     if key.startswith(("DOTNET_", "COMPlus_", "BARRIER_"))},
                        exit_code=result.returncode, log=name + ".log", passed=passed and not qualify_child,
                        input_manifest="benchmark-qualification-input-v" + str(input_version) + "-identities.json",
                        driver_sha256=sha(driver), fixture_sha256=sha(fixture),
                        expected_child_sha256=sha(pin / "bin/Release/net11.0/BarrierBenchmarks.dll")))
    if qualify_child:
        records[-1]["proof_qualified"] = False
    (output / "status.json").write_text(json.dumps(records, indent=2) + "\n")
    if not passed:
        raise RuntimeError("Benchmark control failed; see retained log: " + name)
    if qualify_child:
        directories = set(re.findall(r"^// Execute: .+ in (.+)$", text, re.MULTILINE))
        if len(directories) != 1:
            raise RuntimeError("The exact generated proof child directory was not retained: " + name)
        child = Path(directories.pop()) / "BarrierBenchmarks.dll"
        if not child.is_file():
            raise RuntimeError("The generated proof child is missing: " + str(child))
        records[-1]["executed_fixture_sha256"] = sha(child)
        qualified = records[-1]["executed_fixture_sha256"] == records[-1]["expected_child_sha256"]
        records[-1]["proof_qualified"] = qualified
        records[-1]["passed"] = qualified
        (output / "status.json").write_text(json.dumps(records, indent=2) + "\n")
        if not qualified:
            raise RuntimeError("The generated child is not the separately qualified v4 input.")
    print("PASS " + name, flush=True)


if phase in ("controls", "controls-v4"):
    for revision in frames:
        for kind in ("LXR", "Workstation", "Server"):
            execute(revision + "-" + kind, [str(frames[revision][0] / "corerun"), str(fixture), "--verify"],
                    environment(revision, kind),
                    ["BARRIER requested=" + kind, "diagnostics=False sharedMetrics=0"])
    execute("changed-diagnostics",
            [str(frames["changed"][0] / "corerun"), str(fixture), "--diagnose"],
            environment("changed", "LXR", True),
            ["DIAGNOSTIC first scalar assign", "DIAGNOSTIC repeated bulk fill 8192"])
    execute("baseline-diagnostics",
            ["gdb", "-q", "--batch", "-x", str(evidence / "benchmark-legacy-counters.py"),
             "--args", str(frames["baseline"][0] / "corerun"), str(fixture), "--diagnose-legacy"],
            environment("baseline", "LXR", True),
            ["PASS all 34 legacy first-write/repeated native-counter controls"])
elif phase in ("proof", "proof-v4", "stock-proof"):
    host = os.environ.copy()
    for key in list(host):
        if key.startswith(("DOTNET_", "COMPlus_", "BARRIER_")):
            del host[key]
    for kind in (("LXR",) if phase.startswith("proof") else ("Workstation", "Server")):
        settings = environment("changed", kind)
        command = [str(repo / ".dotnet/dotnet"), "exec", str(fixture), "--filter",
                   "*FirstWrite*" if phase.startswith("proof") else "*FirstWriteScalarStores.Assign",
                   "--job", "Dry", "--invocationCount", "1", "--unrollFactor", "1",
                   "--cli", str(repo / ".dotnet/dotnet"), "--coreRun", str(frames["changed"][0] / "corerun"),
                   "--artifacts", str(output / (kind + "-artifacts")), "--envVars"]
        if input_version == 4:
            command.insert(-1, "--keepFiles")
        command.extend(key + ":" + value for key, value in settings.items()
                       if key.startswith(("DOTNET_", "BARRIER_")))
        execute("first-write-dry-" + kind, command, host,
                ["InvocationCount=1", "UnrollFactor=1", "diagnostics=False sharedMetrics=0",
                 "executed benchmarks: " + ("17" if phase.startswith("proof") else "1")], timeout=900,
                qualify_child=input_version == 4)
elif phase in ("timings", "timings-v4"):
    for prerequisite in (("controls-v4", "proof-v4", "stock-proof") if input_version == 4 else
                         ("controls", "proof", "stock-proof")):
        previous = json.loads((evidence / ("benchmark-v3-" + prerequisite) / "status.json").read_text())
        if not previous or not all(item["passed"] for item in previous):
            raise RuntimeError("Missing or failed prerequisite: " + prerequisite)
        if input_version == 4 and prerequisite == "proof-v4":
            expected_child = sha(pin / "bin/Release/net11.0/BarrierBenchmarks.dll")
            if not all(item.get("proof_qualified") is True and
                       item.get("executed_fixture_sha256") == expected_child and
                       item.get("expected_child_sha256") == expected_child for item in previous):
                raise RuntimeError("The v4 proof lacks qualified generated-child identity.")
    host = os.environ.copy()
    for key in list(host):
        if key.startswith(("DOTNET_", "COMPlus_", "BARRIER_")):
            del host[key]
    for kind in ("LXR", "Workstation", "Server"):
        for storage in ("FirstWrite", "Repeated"):
            for revision in ("baseline", "changed"):
                name = kind + "-" + storage + "-" + revision
                settings = environment(revision, kind)
                command = [str(repo / ".dotnet/dotnet"), "exec", str(fixture),
                           "--filter", "*" + storage + "*", "--job", "Short",
                           "--launchCount", "1", "--warmupCount", "5",
                           "--iterationCount", "30" if storage == "FirstWrite" else "10",
                           "--cli", str(repo / ".dotnet/dotnet"),
                           "--coreRun", str(frames[revision][0] / "corerun"),
                           "--artifacts", str(output / (name + "-artifacts")),
                           "--exporters", "FullJSON", "--keepFiles"]
                if storage == "FirstWrite":
                    command.extend(["--invocationCount", "1", "--unrollFactor", "1"])
                else:
                    command.extend(["--iterationTime", "100"])
                command.append("--envVars")
                command.extend(key + ":" + value for key, value in settings.items()
                               if key.startswith(("DOTNET_", "BARRIER_")))
                required = ["executed benchmarks: 17", "diagnostics=False sharedMetrics=0"]
                if storage == "FirstWrite":
                    required.extend(["InvocationCount=1", "UnrollFactor=1"])
                execute(name, command, host, required, timeout=1800)
                records[-1]["timing_qualified"] = False
                (output / "status.json").write_text(json.dumps(records, indent=2) + "\n")
                reports = list((output / (name + "-artifacts/results")).glob("*full*.json"))
                benchmarks = [item for path in reports
                              for item in json.loads(path.read_text())["Benchmarks"]]
                if len(benchmarks) != 17 or any(item.get("Statistics") is None for item in benchmarks):
                    raise RuntimeError("Expected 17 populated timing records: " + name)
                text = (output / (name + ".log")).read_text(errors="replace")
                directories = set(re.findall(r"^// Execute: .+ in (.+)$", text, re.MULTILINE))
                if len(directories) != 1:
                    raise RuntimeError("The exact generated child directory was not retained: " + name)
                executed_fixture = Path(directories.pop()) / "BarrierBenchmarks.dll"
                if not executed_fixture.is_file() or sha(executed_fixture) != sha(pin / "bin/Release/net11.0/BarrierBenchmarks.dll"):
                    raise RuntimeError("Generated child fixture differs from the pinned input: " + name)
                records[-1]["statistics_count"] = len(benchmarks)
                records[-1]["executed_fixture_sha256"] = sha(executed_fixture)
                records[-1]["timing_qualified"] = True
                records[-1]["reports"] = [dict(path=str(path), sha256=sha(path)) for path in reports]
                (output / "status.json").write_text(json.dumps(records, indent=2) + "\n")
else:
    raise RuntimeError("Unknown phase.")
