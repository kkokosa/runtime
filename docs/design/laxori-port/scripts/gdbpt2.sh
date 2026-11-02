#!/usr/bin/env bash
so="$1"; t="${2:-all}"; sc="${3:-1}"; th="${4:-1}"
mkdir -p /tmp/gdbr
cat > /tmp/gdbr/cmdspt2 <<EOF
set pagination off
set confirm off
handle SIGSEGV stop print nopass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass
handle SIG34 nostop noprint pass
handle SIG35 nostop noprint pass
run
frame 1
p/x object
x/16gx (long)object-64
frame 2
p work->kind
p work->trace
p index
p/x work->references[index]
p/x work->references[index-1]
p/x work->references[index+1]
quit
EOF
env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} DOTNET_GCPath="$so" $EXTRA gdb -batch -x /tmp/gdbr/cmdspt2 --args /root/prof/frame-c4/corerun /root/laxori/pt/bin/PrivateTests.dll "$t" "$sc" "$th" 2>&1 | grep -v '^\[New Thread\|^\[Thread\|LWP' | cut -c1-200 | tail -${TAILN:-60}