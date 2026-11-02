// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Native test of the Laxori write barrier assembly (src/coreclr/gc_laxori/amd64/laxori_writebarrier.S), v2: owner table, private
// bitmap, same-region test and exposed slots. Like the runtime (InitJITWriteBarrierHelpers), the test copies the barrier block to
// an executable page and fills the patchable slots from their source globals. A fake heap, an owner table, a private bitmap and a
// side-metadata array stand in for the GC. The log slow path and the escape slow path are test functions that record their calls
// and damage xmm6 (the helper must restore it).
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

static const size_t HeapBytes = 2 << 20;
static const size_t BlockBytes = 1 << 15;
static const size_t RegionShift = 18;                // 256 KiB regions
static const size_t RegionBytes = static_cast<size_t>(1) << RegionShift;
static uint8_t* g_heap;
static uint8_t* g_metadata;
static uint64_t* g_owner;
static uint8_t* g_bits;
static uintptr_t g_tag;

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

static void SetExposed(void* slot, bool value)
{
    uintptr_t a = reinterpret_cast<uintptr_t>(slot);
    uint8_t* byte = reinterpret_cast<uint8_t*>(Biased(g_bits)) + (a >> 6);
    uint8_t mask = static_cast<uint8_t>(1u << ((a >> 3) & 7));
    *byte = value ? (*byte | mask) : (*byte & ~mask);
}

static void SetOwner(void* region, bool value)
{
    size_t first = (reinterpret_cast<uintptr_t>(region) - reinterpret_cast<uintptr_t>(g_heap)) >> 15;
    for (size_t i = 0; i < RegionBytes / BlockBytes; i++)
    {
        g_owner[first + i] = value ? g_tag : 0;
    }
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

// Calls the helper with a pattern in xmm6; returns 1 when xmm6 is the same after the call.
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
    g_bits = static_cast<uint8_t*>(calloc(HeapBytes / 64 + 16, 1));
    g_owner = static_cast<uint64_t*>(calloc(HeapBytes / BlockBytes + 1, sizeof(uint64_t)));
    memset(g_heap, 0, HeapBytes);
    asm volatile("mov %%fs:0, %0" : "=r"(g_tag));

    LaxoriWriteBarrierSetGlobals(
        Biased(g_metadata), reinterpret_cast<uintptr_t>(g_heap), HeapBytes, reinterpret_cast<void*>(&TestLogPath),
        LaxoriWriteBarrierComputeXsaveMask(), g_owner, Biased(g_bits), RegionShift, reinterpret_cast<void*>(&TestEscapePath));

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

    // Region 0 (the first 256 KiB) is shared. Region 1 is the private region of this thread. Region 2 is shared.
    uint8_t* region1 = g_heap + RegionBytes;
    void** sharedA = reinterpret_cast<void**>(g_heap + 0x100);
    void** sharedB = reinterpret_cast<void**>(g_heap + 2 * RegionBytes + 0x200);
    void** privateA = reinterpret_cast<void**>(region1 + 0x100);
    void** privateB = reinterpret_cast<void**>(region1 + 0x2000);
    void* privateRef = region1 + 0x400;
    void* sharedRef = g_heap + 2 * RegionBytes + 0x800;
    SetOwner(region1, true);

    // 1. private source, private destination of the same region, not exposed: plain store, no log, no escape (even when the
    //    unlog bit of the destination is set).
    Reset();
    SetUnlogged(privateA, true);
    Check(CallHelper(assign, privateA, privateRef) == 1, "vector-private-store");
    Check(*privateA == privateRef && g_logCalls == 0 && g_escapeCalls == 0, "private-to-private-plain-store");
    SetUnlogged(privateA, false);

    // 2. the destination slot is exposed: escape, then the log check (a young slot: its bit is clear), then the store.
    Reset();
    SetExposed(privateB, true);
    Check(CallHelper(assign, privateB, privateRef) == 1, "vector-exposed");
    Check(g_escapeCalls == 1 && g_lastEscapeSlot == privateB && g_lastEscapeRef == privateRef && g_logCalls == 0 &&
        *privateB == privateRef, "exposed-slot-escapes");
    SetExposed(privateB, false);

    // 3. private source, shared destination: escape, then the log check.
    Reset();
    Check(CallHelper(assign, sharedA, privateRef) == 1, "vector-escape-path");
    Check(g_escapeCalls == 1 && g_lastEscapeSlot == sharedA && g_lastEscapeRef == privateRef && g_logCalls == 0 &&
        *sharedA == privateRef, "shared-destination-escapes");

    // 4. the same with the unlog bit set: escape first, then log, then the store.
    Reset();
    SetUnlogged(sharedB, true);
    Check(CallHelper(assign, sharedB, privateRef) == 1, "vector-escape-and-log");
    Check(g_escapeCalls == 1 && g_logCalls == 1 && g_lastLogSlot == sharedB && *sharedB == privateRef && !IsUnlogged(sharedB),
        "escape-then-log-then-store");

    // 5. a destination in a region that is not the region of the source escapes.
    Reset();
    void** otherRegion = reinterpret_cast<void**>(g_heap + 3 * RegionBytes + 0x40);
    CallHelper(assign, otherRegion, privateRef);
    Check(g_escapeCalls == 1 && *otherRegion == privateRef, "other-region-escapes");

    // 6. shared source (the owner entry of its block is not the tag): no escape, the LXR check only.
    Reset();
    Check(CallHelper(assign, sharedA, sharedRef) == 1, "vector-fast-path");
    Check(*sharedA == sharedRef && g_logCalls == 0 && g_escapeCalls == 0, "shared-shared-clear-bit");
    Reset();
    SetUnlogged(sharedA, true);
    CallHelper(assign, sharedA, sharedB);
    Check(g_logCalls == 1 && g_escapeCalls == 0 && *sharedA == sharedB && !IsUnlogged(sharedA), "shared-shared-set-bit-logs-once");

    // 7. a region that another thread owns (a foreign tag in the table) is not a private source for this thread.
    Reset();
    for (size_t i = 0; i < RegionBytes / BlockBytes; i++) g_owner[(RegionBytes / BlockBytes) * 4 + i] = g_tag ^ 0x1000;
    void* foreignRef = g_heap + 4 * RegionBytes + 0x80;
    CallHelper(assign, sharedA, foreignRef);
    Check(g_escapeCalls == 0 && *sharedA == foreignRef, "foreign-owner-is-not-private");

    // 8. null and non-heap references never escape.
    Reset();
    CallHelper(assign, sharedA, nullptr);
    Check(*sharedA == nullptr && g_escapeCalls == 0, "null-reference");
    CallHelper(assign, sharedA, reinterpret_cast<void*>(0x12345678));
    Check(*sharedA == reinterpret_cast<void*>(0x12345678) && g_escapeCalls == 0, "non-heap-reference");

    // 9. the checked helper stores outside the heap without any check, and acts like the other one inside it.
    Reset();
    static void* outside = nullptr;
    CallHelper(checked, &outside, privateRef);
    Check(outside == privateRef && g_escapeCalls == 0 && g_logCalls == 0, "checked-outside-heap");
    CallHelper(checked, sharedA, privateRef);
    Check(*sharedA == privateRef && g_escapeCalls == 1, "checked-inside-heap-escapes");
    Reset();
    CallHelper(checked, privateA, privateRef);
    Check(g_escapeCalls == 0 && *privateA == privateRef, "checked-private-to-private");

    // 10. dissolve: after the owner entries are cleared, the same store is an ordinary shared store.
    Reset();
    SetOwner(region1, false);
    CallHelper(assign, sharedA, privateRef);
    Check(g_escapeCalls == 0 && *sharedA == privateRef, "dissolved-region-is-shared");

    std::printf(g_failures == 0 ? "ALL PASSED\n" : "FAILURES: %d\n", g_failures);
    return g_failures == 0 ? 0 : 1;
}
