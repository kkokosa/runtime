#!/usr/bin/env bash
# usage: gdbpt.sh <so> <test> <scale> <threads> ; runs PrivateTests under gdb and prints the backtrace at the first SIGSEGV
so="$1"; t="${2:-all}"; sc="${3:-1}"; th="${4:-1}"
mkdir -p /tmp/gdbr
cat > /tmp/gdbr/cmdspt <<EOF
set pagination off
set confirm off
handle SIGSEGV stop print nopass
handle SIGUSR1 nostop noprint pass
handle SIGUSR2 nostop noprint pass
handle SIG34 nostop noprint pass
handle SIG35 nostop noprint pass
run
bt 25
info registers rip rdi rsi rax rcx rdx r8
x/8i \$rip-16
quit
EOF
env -i HOME=/root PATH=/usr/bin:/bin DOTNET_gcServer=${SVR:-1} DOTNET_GCPath="$so" $EXTRA \
  gdb -batch -x /tmp/gdbr/cmdspt --args /root/prof/frame-c4/corerun /root/laxori/pt/bin/PrivateTests.dll "$t" "$sc" "$th" 2>&1 | grep -v '^\[New Thread\|^\[Thread\|LWP' | tail -${TAILN:-60}
