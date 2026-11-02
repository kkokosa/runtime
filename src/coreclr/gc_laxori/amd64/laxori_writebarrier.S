// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// The LAXORI write barrier for System V AMD64. The runtime installs it through IGCHeap::GetAssignRefFunctions
// as CORINFO_HELP_ASSIGN_REF and CORINFO_HELP_CHECKED_ASSIGN_REF (the "specialized" barrier ABI).
//
// What the barrier does: before the reference store, it tests the "unlogged" bit of the destination field in side
// metadata (one bit for every 8-byte field slot; a set bit means the field has not been logged in this epoch).
// A clear bit: store and return. A set bit: call the C++ function LaxoriBarrierSlowPath(dst), which reads the old value
// of the field, claims the bit and logs the old value. Then store.
//
// Register contract (the one the JIT assumes for these helpers, see RBM_CALLEE_TRASH_WRITEBARRIER):
//   in:     rdi = destination slot, rsi = new reference
//   killed: rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11 and the flags
//   kept:   every other register, and ALL vector state (xmm0-15, ymm upper halves, zmm0-31, k0-7, mxcsr)
// The fast path is a leaf routine that only uses rax, rcx, r8. The slow path calls C++ code, which may change any
// vector register. So the slow path saves the whole vector state with xsave (fxsave when the OS does not enable
// xsave), calls the C++ function, and restores the state.
//
// Relocation rules (the runtime copies the block to another page):
//   - the block is [LaxoriCheckedAssignRef, LaxoriWriteBarrierBlock_End) and must be relocatable,
//   - inside the block only local labels are used, and all branches are relative, so a copy keeps working,
//   - every value that is not known at build time is read from an 8-byte aligned slot inside the block
//     (the LaxoriPatchable_* labels); the runtime fills the slots (see GCWriteBarrierPatchableValue).
//
// Test controls (the native barrier test builds this file with one of these defines and must see a failure):
//   LAXORI_WB_CONTROL_NO_VECTOR_SAVE    do not save and restore vector state
//   LAXORI_WB_CONTROL_MISALIGN          call the C++ function with a misaligned stack
//   LAXORI_WB_CONTROL_NO_STORE_AFTER_SLOW  forget the store after the slow path

.intel_syntax noprefix
#include "unixasmmacros.inc"

// Size of the xsave area. The mask 0xE7 (x87, SSE, AVX, opmask, ZMM_Hi256, Hi16_ZMM) needs 2688 bytes in the
// standard format. The frame has room for the 64-byte alignment too.
#define LAXORI_XSAVE_FRAME_SIZE 2816
#define LAXORI_XSAVE_HEADER_OFFSET 512

//
//   rdi - destination address (any address; outside the LAXORI heap the helper only stores)
//   rsi - new reference
//
LEAF_ENTRY LaxoriCheckedAssignRef, _TEXT
        mov     rax, rdi
        sub     rax, qword ptr [rip + LOCAL_LABEL(HeapLowSlot)]
        cmp     rax, qword ptr [rip + LOCAL_LABEL(HeapSizeSlot)]
        jb      LOCAL_LABEL(AssignRefEntry)
ALTERNATE_ENTRY LaxoriCheckedAssignRefAVLocation
        mov     [rdi], rsi
        ret
LEAF_END_MARKED LaxoriCheckedAssignRef, _TEXT

//
//   rdi - destination address, must be inside the LAXORI heap
//   rsi - new reference
//
LEAF_ENTRY LaxoriAssignRef, _TEXT
LOCAL_LABEL(AssignRefEntry):
        // metadata byte = base[dst >> 6], bit = (dst >> 3) & 7 (granularity: one bit for every 8 bytes)
        mov     rax, rdi
        shr     rax, 6
        mov     r8, qword ptr [rip + LOCAL_LABEL(MetadataBaseSlot)]
ALTERNATE_ENTRY LaxoriAssignRefMetadataAVLocation
        movzx   eax, byte ptr [rax + r8]
        mov     ecx, edi
        shr     ecx, 3
        and     ecx, 7
        bt      eax, ecx
        jc      LOCAL_LABEL(SlowEntry)
ALTERNATE_ENTRY LaxoriAssignRefAVLocation
        mov     [rdi], rsi
        ret
LEAF_END_MARKED LaxoriAssignRef, _TEXT

//
// Slow path. Entered by a jump from the fast path, so the stack looks as if LaxoriAssignRef was just called.
// A nested function with unwind information. The runtime unwinds copied code through the original address.
//
NESTED_ENTRY LaxoriBarrierSlow, _TEXT, NoHandler
LOCAL_LABEL(SlowEntry):
        push_nonvol_reg rbp
        mov     rbp, rsp
        set_cfa_register rbp, 16
        // keep the arguments: the call below kills rdi and rsi
        push    rdi
        push    rsi
        sub     rsp, LAXORI_XSAVE_FRAME_SIZE
        and     rsp, -64

#ifndef LAXORI_WB_CONTROL_NO_VECTOR_SAVE
        // the header of the xsave area must be zero before xrstor sees it
        xor     eax, eax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 0], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 8], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 16], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 24], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 32], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 40], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 48], rax
        mov     qword ptr [rsp + LAXORI_XSAVE_HEADER_OFFSET + 56], rax

        mov     rax, qword ptr [rip + LOCAL_LABEL(XsaveMaskSlot)]
        test    rax, rax
        jz      LOCAL_LABEL(SaveWithFxsave)
        mov     rdx, rax
        shr     rdx, 32
        xsave   [rsp]
        // C++ code uses legacy SSE encoding. Clear the upper halves, so that it does not pay for mixing with the
        // caller's AVX state; xrstor puts them back.
        test    al, 4
        jz      LOCAL_LABEL(CallManaged)
        vzeroupper
        jmp     LOCAL_LABEL(CallManaged)
LOCAL_LABEL(SaveWithFxsave):
        fxsave  [rsp]
#endif // !LAXORI_WB_CONTROL_NO_VECTOR_SAVE

LOCAL_LABEL(CallManaged):
#ifdef LAXORI_WB_CONTROL_MISALIGN
        sub     rsp, 8
#endif
        // rdi still holds the destination: LaxoriBarrierSlowPath(Object** destination)
        call    qword ptr [rip + LOCAL_LABEL(SlowPathSlot)]
#ifdef LAXORI_WB_CONTROL_MISALIGN
        add     rsp, 8
#endif

#ifndef LAXORI_WB_CONTROL_NO_VECTOR_SAVE
        mov     rax, qword ptr [rip + LOCAL_LABEL(XsaveMaskSlot)]
        test    rax, rax
        jz      LOCAL_LABEL(RestoreWithFxrstor)
        mov     rdx, rax
        shr     rdx, 32
        xrstor  [rsp]
        jmp     LOCAL_LABEL(Restored)
LOCAL_LABEL(RestoreWithFxrstor):
        fxrstor [rsp]
LOCAL_LABEL(Restored):
#endif // !LAXORI_WB_CONTROL_NO_VECTOR_SAVE

        lea     rsp, [rbp - 16]
        pop     rsi
        pop     rdi
        pop     rbp
        .cfi_def_cfa rsp, 8
        .cfi_restore rbp
ALTERNATE_ENTRY LaxoriBarrierSlowAVLocation
#ifndef LAXORI_WB_CONTROL_NO_STORE_AFTER_SLOW
        mov     [rdi], rsi
#endif
        ret
NESTED_END LaxoriBarrierSlow, _TEXT

//
// Patchable slots. Each one is 8-byte aligned, so the runtime updates it with one store. The runtime copies the
// value of a global (named in GetAssignRefFunctions) into the slot of the copied block.
//
        .balign 8
PATCH_LABEL LaxoriPatchable_MetadataBase
LOCAL_LABEL(MetadataBaseSlot):
        .quad   0
PATCH_LABEL LaxoriPatchable_HeapLow
LOCAL_LABEL(HeapLowSlot):
        .quad   0
PATCH_LABEL LaxoriPatchable_HeapSize
LOCAL_LABEL(HeapSizeSlot):
        .quad   0
PATCH_LABEL LaxoriPatchable_SlowPath
LOCAL_LABEL(SlowPathSlot):
        .quad   0
PATCH_LABEL LaxoriPatchable_XsaveMask
LOCAL_LABEL(XsaveMaskSlot):
        .quad   0

        .global C_FUNC(LaxoriWriteBarrierBlock_End)
C_FUNC(LaxoriWriteBarrierBlock_End):
        nop
