#!/usr/bin/env bash
# Null control: base against an identical copy of base, and new. One lock hold for the whole run.
cd /root/p46 || exit 1
cp libs/base.so libs/base2.so
sed -e 's/^            fcntl.flock(lock, fcntl.LOCK_EX)$/            pass/' \
    -e 's/^                fcntl.flock(lock, fcntl.LOCK_UN)$/                pass/' \
    -e 's#^    lock = open("/tmp/lxr-bench.lock", "a")#    lock = open("/tmp/lxr-bench.lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)#' run46.py > run46c.py
grep -c "LOCK_EX" run46c.py
python3 run46c.py /root/p46/null 15 base,base2,new requests,binarytrees,listsuffix > /root/p46/null.out 2>&1
echo done > /root/p46/null.done
