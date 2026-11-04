// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Micro-benchmark of the LXR write barrier assembly (src/coreclr/gc_lxr/amd64/lxr_writebarrier.S).
// It installs a copy of the block as the runtime does, with a fake heap and a fake side-metadata plane, and times
// stores through LxrAssignRef / LxrCheckedAssignRef in these cases (ns per call, minimum and median of the repetitions):
//   seq-clear      sequential slots of a 256 MB heap, unlog bit clear (initialization of young objects)
//   rand-clear     random slots of a 256 MB heap, unlog bit clear (the metadata line is usually not in L1)
//   hot-clear      one slot, bit clear
//   rand-set-mid   random slots, 1 in 8 has the bit set: the slow path with a stub that clears the bit
//   slow-only      every call takes the slow path (the stub only clears the bit)
//   checked-*      the same through the checked entry
// The slow path stub does no logging: the slow-only number is the cost of the assembly around the call
// (frame, vector state save and restore) plus a call and return.
//
//   usage: barrier-microbench [reps]

#include "lxr_write_barrier.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <sys/mman.h>

static const size_t HeapBytes = 256u << 20;
static uint8_t* g_heap;
static uint8_t* g_metadata;

extern "C" void BenchSlowPath(void** slot)
{
    uintptr_t offset = reinterpret_cast<uintptr_t>(slot) - reinterpret_cast<uintptr_t>(g_heap);
    uint8_t* byte = g_metadata + (offset >> 6);
    *byte = static_cast<uint8_t>(*byte & ~(1u << ((offset >> 3) & 7)));
}

struct Installed
{
    uint8_t* copy;
    uint8_t* original;
    void (*assignRef)(void**, void*);
    void (*checkedAssignRef)(void**, void*);
    LxrWriteBarrierBlockInfo info;
};

static void Install(Installed* result)
{
    LxrWriteBarrierGetBlockInfo(&result->info);
    uint8_t* start = reinterpret_cast<uint8_t*>(result->info.checked_assign_ref);
    uint8_t* assign = reinterpret_cast<uint8_t*>(result->info.assign_ref);
    size_t size = static_cast<size_t>(&LxrWriteBarrierBlock_End - start);
    uint8_t* page = static_cast<uint8_t*>(mmap(nullptr, 8192, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    result->copy = page + 64;
    result->original = start;
    std::memcpy(result->copy, start, size);
    result->checkedAssignRef = reinterpret_cast<void (*)(void**, void*)>(result->copy);
    result->assignRef = reinterpret_cast<void (*)(void**, void*)>(result->copy + (assign - start));
    for (LxrWriteBarrierPatchable* p = result->info.patchable; p->slot != nullptr; p++)
    {
        uintptr_t* slot = reinterpret_cast<uintptr_t*>(result->copy + (reinterpret_cast<uint8_t*>(p->slot) - result->original));
        *slot = *reinterpret_cast<uintptr_t*>(p->source);
    }
}

static double Now()
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static uint64_t g_seed = 88172645463325252ull;
static inline uint64_t NextRandom()
{
    g_seed ^= g_seed << 13;
    g_seed ^= g_seed >> 7;
    g_seed ^= g_seed << 17;
    return g_seed;
}

int main(int argc, char** argv)
{
    int reps = argc > 1 ? std::atoi(argv[1]) : 9;
    const uintptr_t align = 2u << 20;
    uint8_t* raw = static_cast<uint8_t*>(mmap(nullptr, HeapBytes + align, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    g_heap = reinterpret_cast<uint8_t*>((reinterpret_cast<uintptr_t>(raw) + align - 1) & ~(align - 1));
    g_metadata = static_cast<uint8_t*>(mmap(nullptr, (HeapBytes >> 6) + 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    std::memset(g_heap, 1, HeapBytes);
    std::memset(g_metadata, 0, HeapBytes >> 6);
    LxrWriteBarrierSetGlobals(
        reinterpret_cast<uintptr_t>(g_metadata) - (reinterpret_cast<uintptr_t>(g_heap) >> 6),
        reinterpret_cast<uintptr_t>(g_heap), HeapBytes, reinterpret_cast<void*>(&BenchSlowPath),
        LxrWriteBarrierComputeXsaveMask());
    Installed b;
    Install(&b);

    const size_t N = 4u << 20;
    std::vector<uint32_t> randomSlots(N);
    for (size_t i = 0; i < N; i++)
    {
        randomSlots[i] = static_cast<uint32_t>(NextRandom() % (HeapBytes / 8));
    }
    void* value = g_heap + 4096;

    struct Case { const char* name; bool checked; int kind; };
    const Case cases[] = {
        {"seq-clear", false, 0}, {"rand-clear", false, 1}, {"hot-clear", false, 2}, {"rand-set-mid", false, 3},
        {"slow-only", false, 4}, {"checked-seq-clear", true, 0}, {"checked-rand-clear", true, 1},
    };
    for (const Case& c : cases)
    {
        auto fn = c.checked ? b.checkedAssignRef : b.assignRef;
        std::vector<double> times;
        size_t n = (c.kind == 4) ? (N / 16) : N;
        for (int rep = 0; rep < reps; rep++)
        {
            std::memset(g_metadata, 0, HeapBytes >> 6);
            if (c.kind == 3 || c.kind == 4)
            {
                for (size_t i = 0; i < n; i++)
                {
                    if (c.kind == 4 || (i & 7) == 0)
                    {
                        uintptr_t offset = static_cast<uintptr_t>(randomSlots[i]) * 8;
                        g_metadata[offset >> 6] |= static_cast<uint8_t>(1u << ((offset >> 3) & 7));
                    }
                }
            }
            double t0 = Now();
            if (c.kind == 0)
            {
                for (size_t i = 0; i < n; i++)
                {
                    fn(reinterpret_cast<void**>(g_heap + (i * 8) % HeapBytes), value);
                }
            }
            else if (c.kind == 2)
            {
                for (size_t i = 0; i < n; i++)
                {
                    fn(reinterpret_cast<void**>(g_heap + 12345 * 8), value);
                }
            }
            else
            {
                for (size_t i = 0; i < n; i++)
                {
                    fn(reinterpret_cast<void**>(g_heap + static_cast<uintptr_t>(randomSlots[i]) * 8), value);
                }
            }
            double t1 = Now();
            times.push_back((t1 - t0) * 1e9 / static_cast<double>(n));
        }
        std::sort(times.begin(), times.end());
        std::printf("%-20s min %7.3f  median %7.3f ns/call\n", c.name, times.front(), times[times.size() / 2]);
    }
    return 0;
}
