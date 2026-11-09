; Licensed to the .NET Foundation under one or more agreements.
; The .NET Foundation licenses this file to you under the MIT license.

; Windows assembly part of laxori-barrier-test.cpp.
;
;   uint64_t TestCallHelper(void* fn, void* dst, void* ref)
;       Fills xmm0-xmm15 with known patterns, calls the write barrier helper fn with rcx = dst and rdx = ref, and returns 1
;       when all sixteen registers have the same value after the call (the helper keeps ALL vector state), else 0.
;   void TestLogPath(void** slot) and void TestEscapePath(void** slot, void* reference)
;       The test slow paths. Each one calls its C++ recorder (TestLogPathC, TestEscapePathC), then clobbers xmm0-xmm15.
;       The recorder gets the arguments unchanged. The helper has to save and restore the vector state around the call.

        .code

Patterns label byte
        dq 1111111111111111h, 2222222222222222h
        dq 3333333333333333h, 4444444444444444h
        dq 5555555555555555h, 6666666666666666h
        dq 7777777777777777h, 8888888888888888h
        dq 9999999999999999h, 0AAAAAAAAAAAAAAAAh
        dq 0BBBBBBBBBBBBBBBBh, 0CCCCCCCCCCCCCCCCh
        dq 0DDDDDDDDDDDDDDDDh, 0EEEEEEEEEEEEEEEEh
        dq 0F0F0F0F0F0F0F0F0h, 0123456789ABCDEFh
        dq 1020304050607080h, 0102030405060708h
        dq 1A1B1C1D1E1F2021h, 2122232425262728h
        dq 3132333435363738h, 4142434445464748h
        dq 5152535455565758h, 6162636465666768h
        dq 7172737475767778h, 8182838485868788h
        dq 9192939495969798h, 0A1A2A3A4A5A6A7A8h
        dq 0B1B2B3B4B5B6B7B8h, 0C1C2C3C4C5C6C7C8h
        dq 0D1D2D3D4D5D6D7D8h, 0E1E2E3E4E5E6E7E8h

; rcx = fn, rdx = dst, r8 = ref
        public TestCallHelper
TestCallHelper proc
        push    rbx
        push    rsi
        push    rdi
        sub     rsp, 192                ; 32 bytes of shadow space and the 160 bytes of the comparison buffer; rsp is 16 byte aligned
        mov     rax, rcx
        mov     rsi, rdx
        mov     rdi, r8
        lea     rbx, Patterns
        movups  xmm0, xmmword ptr [rbx + 0]
        movups  xmm1, xmmword ptr [rbx + 16]
        movups  xmm2, xmmword ptr [rbx + 32]
        movups  xmm3, xmmword ptr [rbx + 48]
        movups  xmm4, xmmword ptr [rbx + 64]
        movups  xmm5, xmmword ptr [rbx + 80]
        movups  xmm6, xmmword ptr [rbx + 96]
        movups  xmm7, xmmword ptr [rbx + 112]
        movups  xmm8, xmmword ptr [rbx + 128]
        movups  xmm9, xmmword ptr [rbx + 144]
        movups  xmm10, xmmword ptr [rbx + 160]
        movups  xmm11, xmmword ptr [rbx + 176]
        movups  xmm12, xmmword ptr [rbx + 192]
        movups  xmm13, xmmword ptr [rbx + 208]
        movups  xmm14, xmmword ptr [rbx + 224]
        movups  xmm15, xmmword ptr [rbx + 240]
        mov     rcx, rsi
        mov     rdx, rdi
        call    rax
        movups  xmmword ptr [rsp + 32 + 0], xmm0
        movups  xmmword ptr [rsp + 32 + 16], xmm1
        movups  xmmword ptr [rsp + 32 + 32], xmm2
        movups  xmmword ptr [rsp + 32 + 48], xmm3
        movups  xmmword ptr [rsp + 32 + 64], xmm4
        movups  xmmword ptr [rsp + 32 + 80], xmm5
        movups  xmmword ptr [rsp + 32 + 96], xmm6
        movups  xmmword ptr [rsp + 32 + 112], xmm7
        movups  xmmword ptr [rsp + 32 + 128], xmm8
        movups  xmmword ptr [rsp + 32 + 144], xmm9
        ; the buffer has room for ten registers only; the other six go to the stack above it
        sub     rsp, 96
        movups  xmmword ptr [rsp + 0], xmm10
        movups  xmmword ptr [rsp + 16], xmm11
        movups  xmmword ptr [rsp + 32], xmm12
        movups  xmmword ptr [rsp + 48], xmm13
        movups  xmmword ptr [rsp + 64], xmm14
        movups  xmmword ptr [rsp + 80], xmm15
        ; compare the first ten registers (160 bytes) and the last six (96 bytes) with the patterns
        lea     rsi, [rsp + 96 + 32]
        lea     rdi, Patterns
        mov     ecx, 20
        repe    cmpsq
        jne     different
        mov     rsi, rsp
        lea     rdi, [Patterns + 160]
        mov     ecx, 12
        repe    cmpsq
        jne     different
        mov     eax, 1
        jmp     done
different:
        xor     eax, eax
done:
        add     rsp, 96
        add     rsp, 192
        pop     rdi
        pop     rsi
        pop     rbx
        ret
TestCallHelper endp

        extern  TestLogPathC:proc
        extern  TestEscapePathC:proc

        public  TestLogPath
TestLogPath proc
        sub     rsp, 40
        call    TestLogPathC
        add     rsp, 40
        jmp     ClobberAndReturn
TestLogPath endp

        public  TestEscapePath
TestEscapePath proc
        sub     rsp, 40
        call    TestEscapePathC
        add     rsp, 40
        jmp     ClobberAndReturn
TestEscapePath endp

ClobberAndReturn proc
        xorps   xmm0, xmm0
        xorps   xmm1, xmm1
        xorps   xmm2, xmm2
        xorps   xmm3, xmm3
        xorps   xmm4, xmm4
        xorps   xmm5, xmm5
        xorps   xmm6, xmm6
        xorps   xmm7, xmm7
        xorps   xmm8, xmm8
        xorps   xmm9, xmm9
        xorps   xmm10, xmm10
        xorps   xmm11, xmm11
        xorps   xmm12, xmm12
        xorps   xmm13, xmm13
        xorps   xmm14, xmm14
        xorps   xmm15, xmm15
        ret
ClobberAndReturn endp

        end
