// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "common.h"
#include "gcenv.h"
#include "gcheaputilities.h"
#include "gchandleutilities.h"

#include "gceventstatus.h"
#include "gcinterface.h"
#include "../../gc/gccapabilities.h"

// This is the global GC heap, maintained by the VM.
GPTR_IMPL(IGCHeap, g_pGCHeap);

// These globals are variables used within the GC and maintained
// by the EE for use in write barriers. It is the responsibility
// of the GC to communicate updates to these globals to the EE through
// GCToEEInterface::StompWriteBarrier.
GPTR_IMPL_INIT(uint32_t, g_card_table,      nullptr);
GPTR_IMPL_INIT(uint8_t,  g_lowest_address,  nullptr);
GPTR_IMPL_INIT(uint8_t,  g_highest_address, nullptr);
GVAL_IMPL_INIT(GCHeapType, g_heap_type,     GC_HEAP_INVALID);
uint8_t* g_ephemeral_low  = (uint8_t*)1;
uint8_t* g_ephemeral_high = (uint8_t*)~0;

#ifdef FEATURE_MANUALLY_MANAGED_CARD_BUNDLES
uint32_t* g_card_bundle_table = nullptr;
#endif

#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
uint8_t* g_write_watch_table = nullptr;
bool g_sw_ww_enabled_for_gc_heap = false;
#endif

IGCHandleManager* g_pGCHandleManager = nullptr;

GcDacVars g_gc_dac_vars;
GPTR_IMPL(GcDacVars, g_gcDacGlobals);
GCWriteBarrierCapabilities g_write_barrier_capabilities;

// GC entrypoints for the linked-in GC. These symbols are invoked
// directly if we are not using a standalone GC.
extern "C" HRESULT LOCALGC_CALLCONV GC_Initialize(
    /* In  */ IGCToCLR* clrToGC,
    /* Out */ IGCHeap** gcHeap,
    /* Out */ IGCHandleManager** gcHandleManager,
    /* Out */ GcDacVars* gcDacVars
);

#ifndef DACCESS_COMPILE

HRESULT InitializeGCSelector();

HRESULT GCHeapUtilities::SelectWriteBarrierCapabilities(IGCHeap* gcHeap, const VersionInfo& version)
{
    GCWriteBarrierCapabilities capabilities = {};
    capabilities.Size = sizeof(capabilities);
    capabilities.Version = GC_WRITE_BARRIER_CAPABILITIES_VERSION;

    if (UsesGCWriteBarrierCapabilities(version.MajorVersion, version.MinorVersion))
    {
        HRESULT result = gcHeap->GetWriteBarrierCapabilities(&capabilities);
        if (FAILED(result))
        {
            LOG((LF_GC, LL_FATALERROR,
                "GC write-barrier capability query failed for interface %u.%u with HR = 0x%X\n",
                version.MajorVersion, version.MinorVersion, result));
            return result;
        }
    }
    else
    {
        capabilities.Kind = GCWriteBarrierKind::CardTable;
    }

    GCWriteBarrierCapabilitiesValidationError error = ValidateGCWriteBarrierCapabilities(capabilities);
    if (error != GCWriteBarrierCapabilitiesValidationError::None)
    {
        LOG((LF_GC, LL_FATALERROR,
            "GC write-barrier declaration for interface %u.%u is invalid: %s\n",
            version.MajorVersion,
            version.MinorVersion,
            GetGCWriteBarrierCapabilitiesValidationErrorMessage(error)));
        return E_INVALIDARG;
    }

    if (capabilities.Kind == GCWriteBarrierKind::SideMetadataFieldLog)
    {
        LOG((LF_GC, LL_FATALERROR,
            "GC write-barrier declaration requests side-metadata field logging, "
            "which NativeAOT recognizes but does not implement\n"));
        return E_NOTIMPL;
    }

    g_write_barrier_capabilities = capabilities;
    return S_OK;
}

const GCWriteBarrierCapabilities& GCHeapUtilities::GetWriteBarrierCapabilities()
{
    return g_write_barrier_capabilities;
}

HRESULT GCHeapUtilities::InitializeGC()
{
    return InitializeGCSelector();
}

HRESULT InitializeDefaultGC()
{
    return GCHeapUtilities::InitializeDefaultGC();
}

// Initializes a non-standalone GC. The protocol for initializing a non-standalone GC
// is similar to loading a standalone one, except that the GC_VersionInfo and
// GC_Initialize symbols are linked to directory and thus don't need to be loaded.
//
HRESULT GCHeapUtilities::InitializeDefaultGC()
{
    // we should only call this once on startup. Attempting to load a GC
    // twice is an error.
    assert(g_pGCHeap == nullptr);

    IGCHeap* heap;
    IGCHandleManager* manager;
    g_gc_dac_vars.major_version_number = GC_INTERFACE_MAJOR_VERSION;
    g_gc_dac_vars.minor_version_number = GC_INTERFACE_MINOR_VERSION;
    HRESULT initResult = GC_Initialize(nullptr, &heap, &manager, &g_gc_dac_vars);
    if (initResult == S_OK)
    {
        VersionInfo version = {};
        version.MajorVersion = GC_INTERFACE_MAJOR_VERSION;
        version.MinorVersion = GC_INTERFACE_MINOR_VERSION;
        initResult = SelectWriteBarrierCapabilities(heap, version);
    }

    if (initResult == S_OK)
    {
        g_pGCHeap = heap;
        g_pGCHandleManager = manager;
        g_gcDacGlobals = &g_gc_dac_vars;
        LOG((LF_GC, LL_INFO100, "GC load successful\n"));
    }
    else
    {
        LOG((LF_GC, LL_FATALERROR, "GC initialization failed with HR = 0x%X\n", initResult));
    }

    return initResult;
}

#endif // DACCESS_COMPILE
