#!/usr/bin/env bash
for rep in $(seq 1 20); do python3 /root/dl/dl-run.py /root/dl/out/ab6 $rep requests new,fix default; done
echo AB6DONE
