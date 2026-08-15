// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc/gccapabilities.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

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
    capabilities.Version = GC_WRITE_BARRIER_CAPABILITIES_LATEST_VERSION;
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

void ExpectTrue(const char* name, bool condition)
{
    checks++;
    if (!condition)
    {
        failures++;
        printf("FAIL %s\n", name);
    }
}

struct QueryContext
{
    GCWriteBarrierCapabilities Capabilities;
    int32_t Result;
    int Calls;
    uint32_t RequestedSize;
    uint32_t RequestedVersion;
};

struct Version2Capabilities
{
    GCWriteBarrierCapabilities Version1;
    uint64_t AddedInVersion2[2];
};

int32_t Query(void* context, GCWriteBarrierCapabilities* capabilities)
{
    QueryContext* query = static_cast<QueryContext*>(context);
    query->Calls++;
    query->RequestedSize = capabilities->Size;
    query->RequestedVersion = capabilities->Version;
    if (query->Result < 0)
    {
        return query->Result;
    }

    uint32_t requestedSize = capabilities->Size;
    uint32_t requestedVersion = capabilities->Version;
    *capabilities = query->Capabilities;
    capabilities->Size = query->Capabilities.Size == 0 ? requestedSize : query->Capabilities.Size;
    capabilities->Version = query->Capabilities.Version == 0 ? requestedVersion : query->Capabilities.Version;
    return query->Result;
}

int32_t Version2CardTableQuery(void* context, GCWriteBarrierCapabilities* capabilities)
{
    QueryContext* query = static_cast<QueryContext*>(context);
    query->Calls++;
    query->RequestedSize = capabilities->Size;
    query->RequestedVersion = capabilities->Version;

    if ((capabilities->Version >= 2) && (capabilities->Size >= sizeof(Version2Capabilities)))
    {
        Version2Capabilities* version2 = reinterpret_cast<Version2Capabilities*>(capabilities);
        if (!TrySetGCWriteBarrierCapabilitiesToCardTable(&version2->Version1))
        {
            return -1;
        }

        version2->Version1.Size = sizeof(Version2Capabilities);
        version2->Version1.Version = 2;
        version2->AddedInVersion2[0] = UINT64_C(0xABCDEF0123456789);
        version2->AddedInVersion2[1] = UINT64_C(0x9876543210FEDCBA);
        return 0;
    }

    return TrySetGCWriteBarrierCapabilitiesToCardTable(capabilities) ? 0 : -1;
}

void ExpectSelection(
    const char* name,
    GCWriteBarrierCapabilitiesSelectionResult actual,
    GCWriteBarrierCapabilitiesSelectionError expected)
{
    checks++;
    if (actual.Error != expected)
    {
        failures++;
        printf("FAIL %s: expected %d, got %d\n", name, static_cast<int>(expected), static_cast<int>(actual.Error));
    }
}
}

int main()
{
    ExpectTrue(
        "old interface versions must not use the appended virtual method",
        !UsesGCWriteBarrierCapabilities(5, 8) && !UsesGCWriteBarrierCapabilities(5, 7));
    ExpectTrue(
        "only interface 5.9 or later uses the appended virtual method",
        UsesGCWriteBarrierCapabilities(5, 9) &&
        UsesGCWriteBarrierCapabilities(5, UINT32_MAX) &&
        !UsesGCWriteBarrierCapabilities(4, UINT32_MAX) &&
        !UsesGCWriteBarrierCapabilities(6, 0));
    ExpectTrue(
        "lower and higher major versions are incompatible",
        IsGCInterfaceMajorVersionCompatible(5, 5) &&
        !IsGCInterfaceMajorVersionCompatible(5, 4) &&
        !IsGCInterfaceMajorVersionCompatible(5, 6));
    ExpectTrue(
        "invalid declarations map to E_INVALIDARG",
        GetGCWriteBarrierCapabilitiesSelectionFailureResult(
            GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration,
            0) == static_cast<int32_t>(UINT32_C(0x80070057)));
    ExpectTrue(
        "unsupported kinds map to E_NOTIMPL",
        GetGCWriteBarrierCapabilitiesSelectionFailureResult(
            GCWriteBarrierCapabilitiesSelectionError::UnsupportedKind,
            0) == static_cast<int32_t>(UINT32_C(0x80004001)));
    ExpectTrue(
        "query failures preserve the collector's HRESULT",
        GetGCWriteBarrierCapabilitiesSelectionFailureResult(
            GCWriteBarrierCapabilitiesSelectionError::QueryFailed,
            static_cast<int32_t>(UINT32_C(0x81234567))) ==
            static_cast<int32_t>(UINT32_C(0x81234567)));

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

    struct FutureCapabilities
    {
        GCWriteBarrierCapabilities Version1;
        uint64_t Canary1;
        uint64_t Canary2;
    };

    FutureCapabilities future = {};
    future.Version1.Size = sizeof(future);
    future.Version1.Version = 2;
    future.Canary1 = UINT64_C(0x1122334455667788);
    future.Canary2 = UINT64_C(0x8877665544332211);
    ExpectTrue(
        "version 1 collector accepts a version 2 caller",
        TrySetGCWriteBarrierCapabilitiesToCardTable(&future.Version1) &&
        (future.Version1.Size == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE) &&
        (future.Version1.Version == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1) &&
        (future.Version1.Kind == GCWriteBarrierKind::CardTable));
    ExpectTrue(
        "version 1 collector does not overwrite a version 2 caller's tail",
        (future.Canary1 == UINT64_C(0x1122334455667788)) &&
        (future.Canary2 == UINT64_C(0x8877665544332211)));

    FutureCapabilities current = {};
    current.Version1.Size = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE;
    current.Version1.Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1;
    current.Canary1 = UINT64_C(0x0102030405060708);
    current.Canary2 = UINT64_C(0x1020304050607080);
    QueryContext futureCollector = {};
    ExpectTrue(
        "version 2 collector accepts a version 1 caller",
        Version2CardTableQuery(&futureCollector, &current.Version1) == 0 &&
        (current.Version1.Size == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE) &&
        (current.Version1.Version == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1) &&
        (futureCollector.RequestedSize == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE) &&
        (futureCollector.RequestedVersion == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1));
    ExpectTrue(
        "version 2 collector does not overwrite a version 1 caller's tail",
        (current.Canary1 == UINT64_C(0x0102030405060708)) &&
        (current.Canary2 == UINT64_C(0x1020304050607080)));

    struct Version2Envelope
    {
        Version2Capabilities Capabilities;
        uint64_t Canary;
    };

    Version2Envelope version2 = {};
    version2.Capabilities.Version1.Size = sizeof(Version2Capabilities);
    version2.Capabilities.Version1.Version = 2;
    version2.Canary = UINT64_C(0x55AA55AA55AA55AA);
    ExpectTrue(
        "version 2 collector returns its larger payload to a version 2 caller",
        Version2CardTableQuery(&futureCollector, &version2.Capabilities.Version1) == 0 &&
        (version2.Capabilities.Version1.Size == sizeof(Version2Capabilities)) &&
        (version2.Capabilities.Version1.Version == 2) &&
        (version2.Capabilities.AddedInVersion2[0] == UINT64_C(0xABCDEF0123456789)) &&
        (version2.Capabilities.AddedInVersion2[1] == UINT64_C(0x9876543210FEDCBA)));
    ExpectTrue(
        "version 2 collector does not overwrite beyond its version 2 payload",
        version2.Canary == UINT64_C(0x55AA55AA55AA55AA));

    FutureCapabilities tooSmall;
    memset(&tooSmall, 0xA5, sizeof(tooSmall));
    tooSmall.Version1.Size = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1_SIZE - 1;
    tooSmall.Version1.Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1;
    FutureCapabilities tooSmallBefore = tooSmall;
    ExpectTrue(
        "one-byte-short caller is rejected without writes",
        !TrySetGCWriteBarrierCapabilitiesToCardTable(&tooSmall.Version1) &&
        (memcmp(&tooSmall, &tooSmallBefore, sizeof(tooSmall)) == 0));
    memset(&tooSmall, 0x5A, sizeof(tooSmall));
    tooSmall.Version1.Size = 0;
    tooSmall.Version1.Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION_1;
    tooSmallBefore = tooSmall;
    ExpectTrue(
        "zero-byte caller is rejected without writes",
        !TrySetGCWriteBarrierCapabilitiesToCardTable(&tooSmall.Version1) &&
        (memcmp(&tooSmall, &tooSmallBefore, sizeof(tooSmall)) == 0));

    QueryContext query = {};
    query.Capabilities = CardTable();
    GCWriteBarrierCapabilities selected = {};
    selected.Kind = static_cast<GCWriteBarrierKind>(UINT32_MAX);
    GCWriteBarrierCapabilitiesSelectionResult selection = SelectGCWriteBarrierCapabilities(
        5, 9, Version2CardTableQuery, &query, &selected);
    ExpectSelection("version 2 collector negotiates with version 1 runtime", selection, GCWriteBarrierCapabilitiesSelectionError::None);
    ExpectTrue(
        "runtime offered its capacity and highest version",
        (query.Calls == 1) &&
        (query.RequestedSize == sizeof(GCWriteBarrierCapabilities)) &&
        (query.RequestedVersion == GC_WRITE_BARRIER_CAPABILITIES_LATEST_VERSION) &&
        (selected.Version == GC_WRITE_BARRIER_CAPABILITIES_VERSION_1));

    query = {};
    selected = {};
    selection = SelectGCWriteBarrierCapabilities(5, 8, Query, &query, &selected);
    ExpectSelection("old collector selects card table without query", selection, GCWriteBarrierCapabilitiesSelectionError::None);
    ExpectTrue(
        "old collector was not queried",
        (query.Calls == 0) && (selected.Kind == GCWriteBarrierKind::CardTable));

    query = {};
    query.Result = INT32_MIN;
    selected = CardTable();
    selected.Reserved = UINT32_C(0x12345678);
    GCWriteBarrierCapabilities selectedBefore = selected;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("query failure is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::QueryFailed);
    ExpectTrue(
        "query failure leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query.Result = -1;
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("second query failure is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::QueryFailed);
    ExpectTrue(
        "second query failure leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query = {};
    query.Capabilities = CardTable();
    query.Capabilities.Size = 1;
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("invalid declaration is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration);
    ExpectTrue(
        "invalid declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query.Capabilities = CardTable();
    query.Capabilities.Kind = static_cast<GCWriteBarrierKind>(UINT32_MAX);
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("second invalid declaration is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration);
    ExpectTrue(
        "second invalid declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query.Capabilities = CardTable();
    query.Capabilities.Size = sizeof(GCWriteBarrierCapabilities) + 1;
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("one-byte oversized declaration is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration);
    ExpectTrue(
        "one-byte oversized declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query.Capabilities.Size = UINT32_MAX;
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("maximum oversized declaration is explicit", selection, GCWriteBarrierCapabilitiesSelectionError::InvalidDeclaration);
    ExpectTrue(
        "maximum oversized declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query = {};
    query.Capabilities = SideMetadata();
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("side metadata remains unsupported", selection, GCWriteBarrierCapabilitiesSelectionError::UnsupportedKind);
    ExpectTrue(
        "unsupported declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    query.Capabilities.SideMetadata.MetadataMeaning = GCWriteBarrierMetadataMeaning::WorkWhenBitIsSet;
    selected = selectedBefore;
    selection = SelectGCWriteBarrierCapabilities(5, 9, Query, &query, &selected);
    ExpectSelection("second valid side-metadata declaration remains unsupported", selection, GCWriteBarrierCapabilitiesSelectionError::UnsupportedKind);
    ExpectTrue(
        "second unsupported declaration leaves selected state unpublished",
        memcmp(&selected, &selectedBefore, sizeof(selected)) == 0);

    printf("%d/%d checks passed\n", checks - failures, checks);
    return failures == 0 ? 0 : 1;
}
