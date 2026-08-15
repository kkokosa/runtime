// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#ifndef GCWRITEBARRIER_H
#define GCWRITEBARRIER_H

#include <stdint.h>

class Object;

enum class GCWriteBarrierKind : uint32_t
{
    CardTable = 0,
    SideMetadataFieldLog = 1,
};

enum class GCWriteBarrierMetadataMeaning : uint8_t
{
    WorkWhenBitIsClear = 0,
    WorkWhenBitIsSet = 1,
};

typedef void (*GCWriteBarrierSlowPath)(
    Object** destination,
    Object* oldReference,
    Object* newReference);

struct GCWriteBarrierSideMetadata
{
    // Called before the field is overwritten when the metadata bit has the
    // requested meaning. The helper must not trigger a garbage collection.
    GCWriteBarrierSlowPath SlowPath;

    // A biased base address. For destination address D, the metadata byte is
    // MetadataBase + (D >> (GranularityShift + 3)). The bit within that byte
    // is (D >> GranularityShift) & 7.
    uint8_t* MetadataBase;

    // The base-2 logarithm of the number of destination bytes represented by
    // one metadata bit.
    uint8_t GranularityShift;

    // Selects whether a clear or set metadata bit requires the slower helper.
    GCWriteBarrierMetadataMeaning MetadataMeaning;

    // Must be zero. Reserved for additive changes to version 1.
    uint8_t Reserved[6];
};

#define GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MAJOR_VERSION 5
#define GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MINOR_VERSION 9

struct GCWriteBarrierCapabilities
{
    uint32_t Size;
    uint32_t Version;
    GCWriteBarrierKind Kind;
    uint32_t Reserved;
    GCWriteBarrierSideMetadata SideMetadata;
};

#define GC_WRITE_BARRIER_CAPABILITIES_VERSION_1 1
#define GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE ((uint32_t)(sizeof(void*) == 8 ? 40 : 32))
#define GC_WRITE_BARRIER_CAPABILITIES_LATEST_VERSION GC_WRITE_BARRIER_CAPABILITIES_VERSION_1

static_assert(sizeof(GCWriteBarrierCapabilities) == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE);

inline bool TrySetGCWriteBarrierCapabilitiesToCardTable(GCWriteBarrierCapabilities* capabilities)
{
    if ((capabilities == nullptr) ||
        (capabilities->Size < GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE) ||
        (capabilities->Version < GC_WRITE_BARRIER_CAPABILITIES_VERSION_1))
    {
        return false;
    }

    capabilities->Size = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE;
    capabilities->Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1;
    capabilities->Kind = GCWriteBarrierKind::CardTable;
    capabilities->Reserved = 0;
    capabilities->SideMetadata.SlowPath = nullptr;
    capabilities->SideMetadata.MetadataBase = nullptr;
    capabilities->SideMetadata.GranularityShift = 0;
    capabilities->SideMetadata.MetadataMeaning = GCWriteBarrierMetadataMeaning::WorkWhenBitIsClear;
    for (uint8_t& reserved : capabilities->SideMetadata.Reserved)
    {
        reserved = 0;
    }

    return true;
}

#endif // GCWRITEBARRIER_H
