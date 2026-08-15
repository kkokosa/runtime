// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#ifdef FEATURE_WRITE_BARRIER_STANDARD_ABI_TEST

#include "gcinternal.h"
#include "standardwritebarriertest.h"

#ifndef DLLEXPORT
#define DLLEXPORT __declspec(dllexport)
#endif

extern "C" uint32_t WriteBarrierTestGetClobberMask();
extern "C" void WriteBarrierTestClobberSse();
extern "C" void WriteBarrierTestClobberAvx();
extern "C" void WriteBarrierTestClobberAvx512();
extern "C" void WriteBarrierTestClobberApx();

namespace
{
constexpr uint32_t VectorClobberMask = 7;
constexpr uint32_t ApxClobberMask = 8;

alignas(64) uint8_t g_write_barrier_test_metadata[64];
volatile int64_t g_write_barrier_test_call_count;
uint32_t g_write_barrier_test_clobber_mask;
void (*g_write_barrier_test_clobber)();

NOINLINE void WriteBarrierTestUncounted(
    Object** destination,
    Object* oldReference,
    Object* newReference)
{
    UNREFERENCED_PARAMETER(destination);
    UNREFERENCED_PARAMETER(oldReference);
    UNREFERENCED_PARAMETER(newReference);
}

NOINLINE void WriteBarrierTestNoOp(
    Object** destination,
    Object* oldReference,
    Object* newReference)
{
    UNREFERENCED_PARAMETER(destination);
    UNREFERENCED_PARAMETER(oldReference);
    UNREFERENCED_PARAMETER(newReference);
    Interlocked::ExchangeAdd64(&g_write_barrier_test_call_count, static_cast<int64_t>(1));
}

NOINLINE void WriteBarrierTestClobber(
    Object** destination,
    Object* oldReference,
    Object* newReference)
{
    UNREFERENCED_PARAMETER(destination);
    UNREFERENCED_PARAMETER(oldReference);
    UNREFERENCED_PARAMETER(newReference);
    Interlocked::ExchangeAdd64(&g_write_barrier_test_call_count, static_cast<int64_t>(1));
    g_write_barrier_test_clobber();
    if ((g_write_barrier_test_clobber_mask & ApxClobberMask) != 0)
    {
        WriteBarrierTestClobberApx();
    }
}
}

uint8_t* GetWriteBarrierTestMetadataBase()
{
    return g_write_barrier_test_metadata;
}

WriteBarrierSlowPath GetWriteBarrierTestSlowPath()
{
    if (GCConfig::GetWriteBarrierTestUncounted())
    {
        return WriteBarrierTestUncounted;
    }

    if (!GCConfig::GetWriteBarrierTestClobber())
    {
        return WriteBarrierTestNoOp;
    }

    g_write_barrier_test_clobber_mask = WriteBarrierTestGetClobberMask();
    switch (g_write_barrier_test_clobber_mask & VectorClobberMask)
    {
        case 4:
            g_write_barrier_test_clobber = WriteBarrierTestClobberAvx512;
            break;

        case 2:
            g_write_barrier_test_clobber = WriteBarrierTestClobberAvx;
            break;

        default:
            g_write_barrier_test_clobber = WriteBarrierTestClobberSse;
            break;
    }

    return WriteBarrierTestClobber;
}

extern "C" DLLEXPORT uint64_t GC_WriteBarrierTest_GetCallCount()
{
    return static_cast<uint64_t>(g_write_barrier_test_call_count);
}

extern "C" DLLEXPORT uint32_t GC_WriteBarrierTest_GetClobberMask()
{
    return g_write_barrier_test_clobber_mask;
}

#endif
