#!/usr/bin/env bash
# usage: pairs.sh <runs.jsonl> <ref> <other>...   prints only the paired-difference part for one reference
f=$1; shift
python3 /root/lxr-locks/analyzelocks.py $f "$@" | sed -n '/^== .* vs /,$p'
