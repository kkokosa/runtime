// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#ifndef GCCAPABILITIES_H
#define GCCAPABILITIES_H

#include "gcwritebarrier.h"

enum class GCWriteBarrierCapabilitiesValidationError
{
    None,
    StructureTooSmall,
    StructureTooLarge,
    UnsupportedStructureVersion,
    UnknownKind,
    MissingMetadataBase,
    MissingSlowPath,
    InvalidGranularityShift,
    UnknownMetadataMeaning,
    ReservedFieldsNotZero,
};

enum class GCWriteBarrierCapabilitiesSelectionError
{
    None,
    QueryFailed,
    InvalidDeclaration,
    UnsupportedKind,
};

struct GCWriteBarrierCapabilitiesSelectionResult
{
    GCWriteBarrierCapabilitiesSelectionError Error;
    GCWriteBarrierCapabilitiesValidationError ValidationError;
    int32_t QueryResult;
};

typedef int32_t (*GCWriteBarrierCapabilitiesQuery)(
    void* context,
    GCWriteBarrierCapabilities* capabilities);

inline bool IsGCInterfaceMajorVersionCompatible(uint32_t runtimeMajorVersion, uint32_t collectorMajorVersion)
{
    return runtimeMajorVersion == collectorMajorVersion;
}

inline bool UsesGCWriteBarrierCapabilities(uint32_t majorVersion, uint32_t minorVersion)
{
    return (majorVersion == GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MAJOR_VERSION) &&
        (minorVersion >= GC_WRITE_BARRIER_CAPABILITIES_INTERFACE_MINOR_VERSION);
}

inline GCWriteBarrierCapabilitiesValidationError ValidateGCWriteBarrierCapabilities(
    const GCWriteBarrierCapabilities& capabilities)
{
    if (capabilities.Size < GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE)
    {
        return GCWriteBarrierCapabilitiesValidationError::StructureTooSmall;
    }

    if ((capabilities.Version < GC_WRITE_BARRIER_CAPABILITIES_VERSION_1) ||
        (capabilities.Version > GC_WRITE_BARRIER_CAPABILITIES_LATEST_VERSION))
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

inline GCWriteBarrierCapabilitiesSelectionResult SelectGCWriteBarrierCapabilities(
    uint32_t majorVersion,
    uint32_t minorVersion,
    GCWriteBarrierCapabilitiesQuery query,
    void* queryContext,
    GCWriteBarrierCapabilities* selectedCapabilities)
{
    GCWriteBarrierCapabilities capabilities = {};
    capabilities.Size = sizeof(capabilities);
    capabilities.Version = GC_WRITE_BARRIER_CAPABILITIES_LATEST_VERSION;
    uint32_t capacity = capabilities.Size;

    int32_t queryResult = 0;
    if (UsesGCWriteBarrierCapabilities(majorVersion, minorVersion))
    {
        queryResult = query(queryContext, &capabilities);
        if (queryResult < 0)
        {
            return {
                GCWriteBarrierCapabilitiesSelectionError::QueryFailed,
                GCWriteBarrierCapabilitiesValidationError::None,
                queryResult
            };
        }
    }
    else if (!TrySetGCWriteBarrierCapabilitiesToCardTable(&capabilities))
    {
        return {
            GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration,
            GCWriteBarrierCapabilitiesValidationError::StructureTooSmall,
            queryResult
        };
    }

    if (capabilities.Size > capacity)
    {
        return {
            GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration,
            GCWriteBarrierCapabilitiesValidationError::StructureTooLarge,
            queryResult
        };
    }

    GCWriteBarrierCapabilitiesValidationError validationError =
        ValidateGCWriteBarrierCapabilities(capabilities);
    if (validationError != GCWriteBarrierCapabilitiesValidationError::None)
    {
        return {
            GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration,
            validationError,
            queryResult
        };
    }

    if (capabilities.Kind == GCWriteBarrierKind::SideMetadataFieldLog)
    {
        return {
            GCWriteBarrierCapabilitiesSelectionError::UnsupportedKind,
            GCWriteBarrierCapabilitiesValidationError::None,
            queryResult
        };
    }

    *selectedCapabilities = capabilities;
    return {
        GCWriteBarrierCapabilitiesSelectionError::None,
        GCWriteBarrierCapabilitiesValidationError::None,
        queryResult
    };
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
        case GCWriteBarrierCapabilitiesValidationError::StructureTooLarge:
            return "the declaration says it wrote beyond the caller's buffer";
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
