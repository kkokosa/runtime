// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc/gccapabilities.h"

#include <stddef.h>
#include <stdio.h>

static_assert(sizeof(GCWriteBarrierCapabilities) == (sizeof(void*) == 8 ? 40 : 32));
static_assert(offsetof(GCWriteBarrierCapabilities, SideMetadata) == 16);

namespace
{
int checks;
int failures;

void SlowPath(Object**, Object*, Object*)
{
}

GCWriteBarrierCapabilities CardTable()
{
    GCWriteBarrierCapabilities capabilities = {};
    capabilities.Size = sizeof(capabilities);
    capabilities.Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION;
    capabilities.Kind = GCWriteBarrierKind::CardTable;
    return capabilities;
}

GCWriteBarrierCapabilities SideMetadata()
{
    static uint8_t metadata;
    GCWriteBarrierCapabilities capabilities = CardTable();
    capabilities.Kind = GCWriteBarrierKind::SideMetadataFieldLog;
    capabilities.SideMetadata.SlowPath = SlowPath;
    capabilities.SideMetadata.MetadataBase = &metadata;
    capabilities.SideMetadata.GranularityShift = 3;
    capabilities.SideMetadata.MetadataMeaning = GCWriteBarrierMetadataMeaning::WorkWhenBitIsClear;
    return capabilities;
}

void Expect(
    const char* name,
    GCWriteBarrierCapabilitiesValidationError actual,
    GCWriteBarrierCapabilitiesValidationError expected)
{
    checks++;
    if (actual != expected)
    {
        failures++;
        printf("FAIL %s: expected %d, got %d\n", name, static_cast<int>(expected), static_cast<int>(actual));
    }
}
}

int main()
{
    checks++;
    if (UsesGCWriteBarrierCapabilities(5, 8) || UsesGCWriteBarrierCapabilities(5, 7))
    {
        failures++;
        printf("FAIL old interface versions must not use the appended virtual method\n");
    }

    checks++;
    if (!UsesGCWriteBarrierCapabilities(5, 9) || !UsesGCWriteBarrierCapabilities(6, 0))
    {
        failures++;
        printf("FAIL new interface versions must use the appended virtual method\n");
    }

    GCWriteBarrierCapabilities value = CardTable();
    Expect("card table", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::None);

    value = SideMetadata();
    Expect("clear bit", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::None);
    value.SideMetadata.MetadataMeaning = GCWriteBarrierMetadataMeaning::WorkWhenBitIsSet;
    Expect("set bit", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::None);

    value = CardTable();
    value.Size = 0;
    Expect("zero size", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::StructureTooSmall);
    value.Size = sizeof(value) - 1;
    Expect("short size", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::StructureTooSmall);

    value = CardTable();
    value.Version = 0;
    Expect("zero version", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnsupportedStructureVersion);
    value.Version = 2;
    Expect("future version", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnsupportedStructureVersion);

    value = CardTable();
    value.Kind = static_cast<GCWriteBarrierKind>(2);
    Expect("unknown kind 2", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnknownKind);
    value.Kind = static_cast<GCWriteBarrierKind>(UINT32_MAX);
    Expect("unknown kind max", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnknownKind);

    value = SideMetadata();
    value.SideMetadata.MetadataBase = nullptr;
    Expect("missing base clear", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::MissingMetadataBase);
    value.SideMetadata.MetadataMeaning = GCWriteBarrierMetadataMeaning::WorkWhenBitIsSet;
    value.SideMetadata.GranularityShift = 4;
    Expect("missing base set", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::MissingMetadataBase);

    value = SideMetadata();
    value.SideMetadata.SlowPath = nullptr;
    Expect("missing helper shift 3", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::MissingSlowPath);
    value.SideMetadata.GranularityShift = 4;
    Expect("missing helper shift 4", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::MissingSlowPath);

    value = SideMetadata();
    value.SideMetadata.GranularityShift = static_cast<uint8_t>((sizeof(uintptr_t) * 8) - 3);
    Expect("shift just too large", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::InvalidGranularityShift);
    value.SideMetadata.GranularityShift = UINT8_MAX;
    Expect("shift max", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::InvalidGranularityShift);

    value = SideMetadata();
    value.SideMetadata.MetadataMeaning = static_cast<GCWriteBarrierMetadataMeaning>(2);
    Expect("unknown meaning 2", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnknownMetadataMeaning);
    value.SideMetadata.MetadataMeaning = static_cast<GCWriteBarrierMetadataMeaning>(UINT8_MAX);
    Expect("unknown meaning max", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::UnknownMetadataMeaning);

    value = CardTable();
    value.Reserved = 1;
    Expect("top reserved 1", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero);
    value.Reserved = UINT32_MAX;
    Expect("top reserved max", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero);

    value = SideMetadata();
    value.SideMetadata.Reserved[0] = 1;
    Expect("side reserved first", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero);
    value.SideMetadata.Reserved[0] = 0;
    value.SideMetadata.Reserved[5] = UINT8_MAX;
    Expect("side reserved last", ValidateGCWriteBarrierCapabilities(value), GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero);

    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
