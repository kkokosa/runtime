// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#ifndef GCCAPABILITIES_H
#define GCCAPABILITIES_H

#include "gcwritebarrier.h"

enum class GCWriteBarrierCapabilitiesValidationError
{
    None,
    StructureTooSmall,
    UnsupportedStructureVersion,
    UnknownKind,
    MissingMetadataBase,
    MissingSlowPath,
    InvalidGranularityShift,
    UnknownMetadataMeaning,
    ReservedFieldsNotZero,
};

inline bool UsesGCWriteBarrierCapabilities(uint32_t majorVersion, uint32_t minorVersion)
{
    return (majorVersion > GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MAJOR_VERSION) ||
        ((majorVersion == GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MAJOR_VERSION) &&
         (minorVersion >= GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MINOR_VERSION));
}

inline GCWriteBarrierCapabilitiesValidationError ValidateGCWriteBarrierCapabilities(
    const GCWriteBarrierCapabilities& capabilities)
{
    if (capabilities.Size < sizeof(GCWriteBarrierCapabilities))
    {
        return GCWriteBarrierCapabilitiesValidationError::StructureTooSmall;
    }

    if (capabilities.Version != GC_WRITE_BARRIER_CAPABILITIES_VERSION)
    {
        return GCWriteBarrierCapabilitiesValidationError::UnsupportedStructureVersion;
    }

    if (capabilities.Reserved != 0)
    {
        return GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero;
    }

    for (uint8_t reserved : capabilities.SideMetadata.Reserved)
    {
        if (reserved != 0)
        {
            return GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero;
        }
    }

    switch (capabilities.Kind)
    {
        case GCWriteBarrierKind::CardTable:
            return GCWriteBarrierCapabilitiesValidationError::None;

        case GCWriteBarrierKind::SideMetadataFieldLog:
            if (capabilities.SideMetadata.MetadataBase == nullptr)
            {
                return GCWriteBarrierCapabilitiesValidationError::MissingMetadataBase;
            }

            if (capabilities.SideMetadata.SlowPath == nullptr)
            {
                return GCWriteBarrierCapabilitiesValidationError::MissingSlowPath;
            }

            if (capabilities.SideMetadata.GranularityShift > ((sizeof(uintptr_t) * 8) - 4))
            {
                return GCWriteBarrierCapabilitiesValidationError::InvalidGranularityShift;
            }

            if ((capabilities.SideMetadata.MetadataMeaning != GCWriteBarrierMetadataMeaning::WorkWhenBitIsClear) &&
                (capabilities.SideMetadata.MetadataMeaning != GCWriteBarrierMetadataMeaning::WorkWhenBitIsSet))
            {
                return GCWriteBarrierCapabilitiesValidationError::UnknownMetadataMeaning;
            }

            return GCWriteBarrierCapabilitiesValidationError::None;

        default:
            return GCWriteBarrierCapabilitiesValidationError::UnknownKind;
    }
}

inline const char* GetGCWriteBarrierCapabilitiesValidationErrorMessage(
    GCWriteBarrierCapabilitiesValidationError error)
{
    switch (error)
    {
        case GCWriteBarrierCapabilitiesValidationError::None:
            return "no error";
        case GCWriteBarrierCapabilitiesValidationError::StructureTooSmall:
            return "the declaration is smaller than version 1 requires";
        case GCWriteBarrierCapabilitiesValidationError::UnsupportedStructureVersion:
            return "the declaration uses an unsupported structure version";
        case GCWriteBarrierCapabilitiesValidationError::UnknownKind:
            return "the declaration requests an unknown write-barrier kind";
        case GCWriteBarrierCapabilitiesValidationError::MissingMetadataBase:
            return "the side-metadata declaration has no metadata base address";
        case GCWriteBarrierCapabilitiesValidationError::MissingSlowPath:
            return "the side-metadata declaration has no slower helper";
        case GCWriteBarrierCapabilitiesValidationError::InvalidGranularityShift:
            return "the side-metadata declaration has an invalid address granularity shift";
        case GCWriteBarrierCapabilitiesValidationError::UnknownMetadataMeaning:
            return "the side-metadata declaration has an unknown bit meaning";
        case GCWriteBarrierCapabilitiesValidationError::ReservedFieldsNotZero:
            return "the declaration has nonzero reserved fields";
        default:
            return "the declaration is invalid";
    }
}

#endif // GCCAPABILITIES_H
