// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Native test of the Laxori write barrier assembly (src/coreclr/gc_laxori/amd64/laxori_writebarrier.S).
// Like the runtime (InitJITWriteBarrierHelpers), the test copies the barrier block to an executable page and fills the
// patchable slots from their source globals. A fake heap, a block table and a side-metadata array stand in for the GC. The
// log slow path and the escape slow path are test functions that record their calls and damage xmm6.
// Every check prints PASS: <name> or FAIL: <name>. Exit code 0 = all passed.

#include "laxori_write_barrier.h"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>

static int g_failures = 0;
static void Check(bool ok, const char* name)
{
    if (!ok)
    {
        g_failures++;
    }
    std::printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
}

static const size_t HeapBytes = 1 << 20;
static const size_t BlockBytes = 1 << 15;
static uint8_t* g_heap;
static uint8_t* g_metadata;
static uint8_t* g_table;

static int g_logCalls;
static int g_escapeCalls;
static void** g_lastLogSlot;
static void** g_lastEscapeSlot;
static void* g_lastEscapeRef;

static uintptr_t Biased(uint8_t* storage)
{
    return reinterpret_cast<uintptr_t>(storage) - (reinterpret_cast<uintptr_t>(g_heap) >> 6);
}

static void SetUnlogged(void** slot, bool value)
{
    uintptr_t a = reinterpret_cast<uintptr_t>(slot);
    uint8_t* byte = reinterpret_cast<uint8_t*>(Biased(g_metadata)) + (a >> 6);
    uint8_t mask = static_cast<uint8_t>(1u << ((a >> 3) & 7));
    *byte = value ? (*byte | mask) : (*byte & ~mask);
}

static bool IsUnlogged(void** slot)
{
    uintptr_t a = reinterpret_cast<uintptr_t>(slot);
    uint8_t* byte = reinterpret_cast<uint8_t*>(Biased(g_metadata)) + (a >> 6);
    return (*byte >> ((a >> 3) & 7)) & 1;
}

static void SetPrivate(void* address, bool value)
{
    g_table[(reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(g_heap)) >> 15] = value ? 1 : 0;
}

extern "C" void TestLogPath(void** slot)
{
    g_logCalls++;
    g_lastLogSlot = slot;
    SetUnlogged(slot, false);
    asm volatile("pxor %%xmm6, %%xmm6" ::: "xmm6");
}

extern "C" void TestEscapePath(void** slot, void* reference)
{
    g_escapeCalls++;
    g_lastEscapeSlot = slot;
    g_lastEscapeRef = reference;
    asm volatile("pxor %%xmm6, %%xmm6" ::: "xmm6");
}

typedef void (*Helper)(void**, void*);

// Calls the helper with a pattern in xmm6; returns the value of xmm6 after the call.
static uint64_t CallHelper(Helper fn, void** dst, void* ref)
{
    uint64_t pattern = 0x1122334455667788ull;
    uint64_t out;
    asm volatile(
        "movq %[pat], %%xmm6\n\t"
        "mov %[dst], %%rdi\n\t"
        "mov %[ref], %%rsi\n\t"
        "sub $128, %%rsp\n\t"
        "call *%[fn]\n\t"
        "add $128, %%rsp\n\t"
        "movq %%xmm6, %[out]\n\t"
        : [out] "=r"(out)
        : [pat] "r"(pattern), [dst] "r"(dst), [ref] "r"(ref), [fn] "r"(fn)
        : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "xmm6", "memory", "cc");
    return out == pattern ? 1 : 0;
}

static void Reset()
{
    g_logCalls = 0;
    g_escapeCalls = 0;
    g_lastLogSlot = nullptr;
    g_lastEscapeSlot = nullptr;
    g_lastEscapeRef = nullptr;
}

int main()
{
    g_heap = static_cast<uint8_t*>(aligned_alloc(HeapBytes, HeapBytes));
    g_metadata = static_cast<uint8_t*>(calloc(HeapBytes / 64 + 16, 1));
    g_table = static_cast<uint8_t*>(calloc(HeapBytes / BlockBytes + 1, 1));
    memset(g_heap, 0, HeapBytes);

    LaxoriWriteBarrierSetGlobals(
        Biased(g_metadata), reinterpret_cast<uintptr_t>(g_heap), HeapBytes, reinterpret_cast<void*>(&TestLogPath),
        LaxoriWriteBarrierComputeXsaveMask(), g_table, reinterpret_cast<void*>(&TestEscapePath));

    LaxoriWriteBarrierBlockInfo info;
    LaxoriWriteBarrierGetBlockInfo(&info);
    uint8_t* original = static_cast<uint8_t*>(info.checked_assign_ref);
    size_t size = info.checked_assign_ref_size;
    uint8_t* page = static_cast<uint8_t*>(mmap(nullptr, 8192, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    memcpy(page, original, size);
    for (LaxoriWriteBarrierPatchable* p = info.patchable; p->slot != nullptr; p++)
    {
        size_t offset = static_cast<uint8_t*>(p->slot) - original;
        memcpy(page + offset, p->source, sizeof(uintptr_t));
    }
    Helper checked = reinterpret_cast<Helper>(page);
    Helper assign = reinterpret_cast<Helper>(page + (static_cast<uint8_t*>(info.assign_ref) - original));

    // Block 0 is shared, block 1 is private, block 2 is shared.
    void** sharedA = reinterpret_cast<void**>(g_heap + 0x100);
    void** privateA = reinterpret_cast<void**>(g_heap + BlockBytes + 0x100);
    void** sharedB = reinterpret_cast<void**>(g_heap + 2 * BlockBytes + 0x200);
    void* privateRef = g_heap + BlockBytes + 0x400;
    void* sharedRef = g_heap + 2 * BlockBytes + 0x800;
    SetPrivate(privateA, true);

    // 1. A store into a private block does not log (even if the unlog bit is set) and does not escape.
    Reset();
    SetUnlogged(privateA, true);
    Check(CallHelper(assign, privateA, privateRef) == 1, "vector-private-store");
    Check(*privateA == privateRef && g_logCalls == 0 && g_escapeCalls == 0, "private-dst-plain-store");
    SetUnlogged(privateA, false);

    // 2. Shared destination, shared reference, bit clear: plain store.
    Reset();
    Check(CallHelper(assign, sharedA, sharedRef) == 1, "vector-fast-path");
    Check(*sharedA == sharedRef && g_logCalls == 0 && g_escapeCalls == 0, "shared-shared-clear-bit");

    // 3. Same with the unlog bit set: the log path runs once, then the store.
    Reset();
    SetUnlogged(sharedA, true);
    Check(CallHelper(assign, sharedA, sharedB) == 1, "vector-log-path");
    Check(g_logCalls == 1 && g_lastLogSlot == sharedA && g_escapeCalls == 0 && *sharedA == sharedB && !IsUnlogged(sharedA),
        "shared-shared-set-bit-logs-once");

    // 4. Shared destination, private reference, bit clear: the escape path runs once, then the store.
    Reset();
    Check(CallHelper(assign, sharedA, privateRef) == 1, "vector-escape-path");
    Check(g_escapeCalls == 1 && g_lastEscapeSlot == sharedA && g_lastEscapeRef == privateRef && g_logCalls == 0 &&
        *sharedA == privateRef, "escape-once-then-store");

    // 5. Shared destination, private reference, bit set: escape first, then log, then the store.
    Reset();
    SetUnlogged(sharedB, true);
    Check(CallHelper(assign, sharedB, privateRef) == 1, "vector-escape-and-log");
    Check(g_escapeCalls == 1 && g_logCalls == 1 && g_lastLogSlot == sharedB && *sharedB == privateRef,
        "escape-then-log-then-store");

    // 6. Null and non-heap references never take the escape path.
    Reset();
    CallHelper(assign, sharedA, nullptr);
    Check(*sharedA == nullptr && g_escapeCalls == 0, "null-reference");
    CallHelper(assign, sharedA, reinterpret_cast<void*>(0x12345678));
    Check(*sharedA == reinterpret_cast<void*>(0x12345678) && g_escapeCalls == 0, "non-heap-reference");

    // 7. The checked helper stores outside the heap without any check, and acts like the other one inside it.
    Reset();
    static void* outside = nullptr;
    CallHelper(checked, &outside, privateRef);
    Check(outside == privateRef && g_escapeCalls == 0 && g_logCalls == 0, "checked-outside-heap");
    CallHelper(checked, sharedA, privateRef);
    Check(*sharedA == privateRef && g_escapeCalls == 1, "checked-inside-heap-escapes");

    // 8. A private reference stored into a private block of the same region: no escape.
    Reset();
    CallHelper(checked, privateA, privateRef);
    Check(g_escapeCalls == 0 && *privateA == privateRef, "private-to-private");

    std::printf(g_failures == 0 ? "ALL PASSED\n" : "FAILURES: %d\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
