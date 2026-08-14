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

#define GC_WRITE_BARRIER_CAPABILITIES_VERSION 1
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

#endif // GCWRITEBARRIER_H
