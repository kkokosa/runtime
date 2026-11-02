#!/usr/bin/env bash
# Runs the Laxori copies of the native engine validation programs. usage: run-native-all.sh <repo root as WSL path> <output root>
root="$1"; out="${2:-/tmp/laxori-native}"
rm -rf "$out"; mkdir -p "$out"
D="$root/docs/design/laxori-port"
fail=0
run() { name="$1"; shift; echo "== $name"; if nice -n 10 "$@" > "$out/$name.log" 2>&1; then tail -n 2 "$out/$name.log"; else echo "FAILED $name"; tail -n 15 "$out/$name.log"; fail=1; fi; }
run p2.1 bash "$D/P2.1/run-side-metadata-validation.sh" "$root" "$out/p2.1"
run p2.2 bash "$D/P2.2/run-immix-block-validation.sh" "$root" "$out/p2.2"
run p2.3 bash "$D/P2.3/run-reference-count-validation.sh" "$root" "$out/p2.3"
run p2.4 bash "$D/P2.4/run-immix-allocation-validation.sh" "$root" "$out/p2.4"
run p2.5 bash "$D/P2.5/run-large-object-space-validation.sh" "$root" "$out/p2.5"
run p3.1 bash "$D/P3.1/run-laxori-work-packet-validation.sh" "$root" "$out/p3.1"
run p3.2 bash "$D/P3.2/run-laxori-pause-validation.sh" "$root" "$out/p3.2"
run p3.3 bash "$D/P3.3/run-laxori-deferred-bucket-validation.sh" "$root" "$out/p3.3"
run p3.4 bash "$D/P3.4/run-laxori-completion-counter-validation.sh" "$root" "$out/p3.4"
run p4-release bash "$D/P4/run-laxori-rc-vertical.sh" Release "$out/p4-release"
echo "native failed=$fail"
exit $fail
