// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc/env/common.h"
#include "../../../../src/coreclr/gc/env/gcenv.h"
#include "../../../../src/coreclr/gc/side_metadata.h"

#include <atomic>
#include <stdlib.h>
#include <thread>

#ifdef _MSC_VER
#define P21_EXPORT extern "C" __declspec(dllexport)
#define P21_NOINLINE __declspec(noinline)
#else
#define P21_EXPORT extern "C" __attribute__((visibility("default")))
#define P21_NOINLINE __attribute__((noinline))
#endif

namespace
{
constexpr uintptr_t DataStart = UINT64_C(0x0000000300000000);
constexpr size_t DataSize = 4 * 1024 * 1024;
constexpr size_t AddressCount = 4096;
constexpr size_t FalseSharingIterations = 10000;

LxrSideMetadataLayout* s_layout;
SideMetadataManager* s_manager;
std::thread s_false_sharing_first;
std::thread s_false_sharing_second;
std::atomic<uint32_t> s_false_sharing_generation;
std::atomic<uint32_t> s_false_sharing_completed;
std::atomic<size_t> s_false_sharing_distance;
std::atomic<bool> s_false_sharing_failed;
std::atomic<bool> s_false_sharing_stopping;

struct BulkChecksum
{
    uintptr_t value;
};

bool AccumulateWord(uintptr_t address, uintptr_t value, uintptr_t coverage, void* context)
{
    BulkChecksum* checksum = static_cast<BulkChecksum*>(context);
    checksum->value ^= address + (value & coverage);
    return true;
}

uintptr_t AddressAt(size_t index)
{
    return DataStart + ((index & (AddressCount - 1)) * 8);
}

void FalseSharingWorker(bool second)
{
    uint32_t observedGeneration = 0;
    while (true)
    {
        uint32_t generation;
        while ((generation = s_false_sharing_generation.load(std::memory_order_seq_cst)) ==
            observedGeneration)
        {
            std::this_thread::yield();
        }
        observedGeneration = generation;
        if (s_false_sharing_stopping.load(std::memory_order_seq_cst))
        {
            return;
        }

        uintptr_t address = DataStart;
        if (second)
        {
            address += s_false_sharing_distance.load(std::memory_order_seq_cst);
        }
        for (size_t index = 0; index < FalseSharingIterations; index++)
        {
            if (s_manager->Store(
                    LxrSideMetadataKind::FieldUnlogged,
                    address,
                    index & 1,
                    SideMetadataMemoryOrder::SequentiallyConsistent) !=
                SideMetadataResult::Success)
            {
                s_false_sharing_failed.store(true, std::memory_order_seq_cst);
                break;
            }
        }
        s_false_sharing_completed.fetch_add(1, std::memory_order_seq_cst);
    }
}

void StartFalseSharingWorkers()
{
    s_false_sharing_generation.store(0, std::memory_order_seq_cst);
    s_false_sharing_completed.store(0, std::memory_order_seq_cst);
    s_false_sharing_distance.store(0, std::memory_order_seq_cst);
    s_false_sharing_failed.store(false, std::memory_order_seq_cst);
    s_false_sharing_stopping.store(false, std::memory_order_seq_cst);
    s_false_sharing_first = std::thread(FalseSharingWorker, false);
    s_false_sharing_second = std::thread(FalseSharingWorker, true);
}

void StopFalseSharingWorkers()
{
    if (!s_false_sharing_first.joinable())
    {
        return;
    }

    s_false_sharing_stopping.store(true, std::memory_order_seq_cst);
    s_false_sharing_generation.fetch_add(1, std::memory_order_seq_cst);
    s_false_sharing_first.join();
    s_false_sharing_second.join();
}

uintptr_t ResetBatch(size_t operationCount, size_t dataSize)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t value = index & 1;
        if (s_manager->ResetRangeQuiescent(
                LxrSideMetadataKind::FieldUnlogged,
                DataStart,
                dataSize,
                value) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
        checksum += value;
    }
    return checksum;
}

int32_t Initialize(uint8_t logReferenceCountBits, size_t dataSize)
{
    s_layout = new (nothrow) LxrSideMetadataLayout;
    s_manager = new (nothrow) SideMetadataManager;
    if ((s_layout == nullptr) || (s_manager == nullptr))
    {
        return -2;
    }

    if (LxrSideMetadataLayout::Create(logReferenceCountBits, s_layout) != SideMetadataResult::Success)
    {
        return -3;
    }
    if (s_manager->Initialize(s_layout) != SideMetadataResult::Success)
    {
        return -4;
    }
    if (s_manager->CommitDataRange(DataStart, dataSize) != SideMetadataResult::Success)
    {
        return -5;
    }

    StartFalseSharingWorkers();
    return 0;
}

void Shutdown()
{
    StopFalseSharingWorkers();
    delete s_manager;
    delete s_layout;
    s_manager = nullptr;
    s_layout = nullptr;
}
}

P21_EXPORT int32_t P21_Initialize(uint8_t logReferenceCountBits)
{
    if (s_manager != nullptr)
    {
        return -1;
    }

    int32_t result = Initialize(logReferenceCountBits, DataSize);
    if (result != 0)
    {
        Shutdown();
    }
    return result;
}

P21_EXPORT void P21_Shutdown()
{
    Shutdown();
}

P21_EXPORT P21_NOINLINE uintptr_t P21_MapLoadBatch(size_t operationCount)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t value;
        if (s_manager->Load(
                LxrSideMetadataKind::FieldUnlogged,
                AddressAt(index),
                SideMetadataMemoryOrder::SequentiallyConsistent,
                &value) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
        checksum += value + index;
    }
    return checksum;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_PrecomputedLoadBatch(size_t operationCount)
{
    SideMetadataLocation location;
    if (s_manager->GetLocation(
            LxrSideMetadataKind::FieldUnlogged,
            DataStart,
            &location) != SideMetadataResult::Success)
    {
        return UINTPTR_MAX;
    }

    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        checksum += VolatileLoadWithoutBarrier(location.word) + index;
    }
    return checksum;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_BitStoreBatch(size_t operationCount)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t value = index & 1;
        if (s_manager->Store(
                LxrSideMetadataKind::FieldUnlogged,
                AddressAt(index),
                value,
                SideMetadataMemoryOrder::SequentiallyConsistent) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
        checksum += value;
    }
    return checksum;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_ReferenceCountBatch(size_t operationCount)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t previous;
        if (s_manager->FetchAddWrapping(
                LxrSideMetadataKind::ReferenceCount,
                AddressAt(index),
                1,
                SideMetadataMemoryOrder::Relaxed,
                &previous) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
        checksum += previous;
    }
    return checksum;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_ByteUpdateBatch(size_t operationCount)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t previous;
        uintptr_t address = DataStart + ((index & 127) * (32 * 1024));
        if (s_manager->FetchAddWrapping(
                LxrSideMetadataKind::PhaseEpoch,
                address,
                1,
                SideMetadataMemoryOrder::SequentiallyConsistent,
                &previous) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
        checksum += previous;
    }
    return checksum;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_BulkReadBatch(size_t operationCount)
{
    BulkChecksum checksum = {};
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t start = DataStart + ((index & 7) * 8);
        if (s_manager->VisitWords(
                LxrSideMetadataKind::FieldUnlogged,
                start,
                64 * 1024,
                SideMetadataMemoryOrder::SequentiallyConsistent,
                AccumulateWord,
                &checksum) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
    }
    return checksum.value;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_SparseBulkReadBatch(size_t operationCount)
{
    BulkChecksum checksum = {};
    for (size_t index = 0; index < operationCount; index++)
    {
        uintptr_t start = DataStart + ((index & 511) * 4096);
        if (s_manager->VisitWords(
                LxrSideMetadataKind::FieldUnlogged,
                start,
                64,
                SideMetadataMemoryOrder::SequentiallyConsistent,
                AccumulateWord,
                &checksum) != SideMetadataResult::Success)
        {
            return UINTPTR_MAX;
        }
    }
    return checksum.value;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_Reset4KiBBatch(size_t operationCount)
{
    return ResetBatch(operationCount, 4 * 1024);
}

P21_EXPORT P21_NOINLINE uintptr_t P21_Reset64KiBBatch(size_t operationCount)
{
    return ResetBatch(operationCount, 64 * 1024);
}

P21_EXPORT P21_NOINLINE uintptr_t P21_Reset1MiBBatch(size_t operationCount)
{
    return ResetBatch(operationCount, 1024 * 1024);
}

P21_EXPORT P21_NOINLINE uintptr_t P21_ReserveAndFirstCommit(uint8_t logReferenceCountBits)
{
    Shutdown();
    return static_cast<uintptr_t>(Initialize(logReferenceCountBits, 4096));
}

P21_EXPORT P21_NOINLINE uintptr_t P21_FalseSharingBatch(size_t dataDistance)
{
    s_false_sharing_distance.store(dataDistance, std::memory_order_seq_cst);
    s_false_sharing_failed.store(false, std::memory_order_seq_cst);
    s_false_sharing_completed.store(0, std::memory_order_seq_cst);
    s_false_sharing_generation.fetch_add(1, std::memory_order_seq_cst);
    while (s_false_sharing_completed.load(std::memory_order_seq_cst) != 2)
    {
        std::this_thread::yield();
    }
    return s_false_sharing_failed.load(std::memory_order_seq_cst)
        ? UINTPTR_MAX
        : dataDistance;
}

P21_EXPORT P21_NOINLINE uintptr_t P21_ExtraCasSensitivityBatch(size_t operationCount)
{
    uintptr_t checksum = 0;
    for (size_t index = 0; index < operationCount; index++)
    {
        for (size_t repeat = 0; repeat < 8; repeat++)
        {
            uintptr_t value = (index + repeat) & 1;
            if (s_manager->Store(
                    LxrSideMetadataKind::FieldUnlogged,
                    AddressAt(index),
                    value,
                    SideMetadataMemoryOrder::SequentiallyConsistent) != SideMetadataResult::Success)
            {
                return UINTPTR_MAX;
            }
            checksum += value;
        }
    }
    return checksum;
}
