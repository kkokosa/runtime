#!/usr/bin/env bash
for v in old prev new; do
  echo "== $v"
  flock /tmp/lxr-bench.lock bash /root/dl/rss.sh /root/dl/libs/libclrlxrgc-$v.so
done
