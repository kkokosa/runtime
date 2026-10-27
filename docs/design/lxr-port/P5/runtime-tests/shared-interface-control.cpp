// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "common.h"
#include "gcenv.structs.h"
#define ASSERT(expression) assert(expression)
#include "gcenv.base.h"

class IGCToCLR;
struct GcDacVars;
#include "gcinterface.h"
#include "gcinterface.ee.h"

#ifdef TARGET_WINDOWS
#define CONTROL_EXPORT extern "C" __declspec(dllexport)
#else
#define CONTROL_EXPORT extern "C" __attribute__((visibility("default")))
#endif // TARGET_WINDOWS

#if !defined(FEATURE_NATIVEAOT) || defined(NDEBUG)
#error This control requires assertion-enabled native sample interface defaults.
#endif

namespace
{
    uint32_t eeMajor;
    uint32_t eeMinor;

    bool Mode(const char* expected)
    {
        const char* mode = getenv("SHARED_INTERFACE_CONTROL");
        return mode != nullptr && strcmp(mode, expected) == 0;
    }

    void Unexpected()
    {
        fputs("FAIL: the runtime published an invalid fast-function table.\n", stderr);
        abort();
    }

    void PostStore(void*, Object**, Object*) { Unexpected(); }
    void PreStore(Object**, Object*) { Unexpected(); }
    bool IsInHeap(void*, void*) { Unexpected(); return false; }
    void Move(void*, void*, const void*, size_t) { Unexpected(); }
    void Clear(void*, void*, size_t) { Unexpected(); }
    void ObsoleteRange(void*, Object**, Object**, size_t) { Unexpected(); }

    class ControlHeap final : public IGCHeap
    {
        ObjectReferenceEnumerationParameters m_enumeration = {};
        ObjectHeaderBitsParameters m_headerBits = {};

    public:
        GCHeapType GetGCHeapType() override { return Mode("non-custom") ? GC_HEAP_WKS : GC_HEAP_CUSTOM; }

        ObjectReferenceEnumerationParameters* GetObjectReferenceEnumerationParameters() override
        {
            fputs("CONTROL enumeration-descriptor\n", stderr);
            return &m_enumeration;
        }

        ObjectHeaderBitsParameters* GetObjectHeaderBitsParameters() override
        {
            fputs("CONTROL header-descriptor\n", stderr);
            return &m_headerBits;
        }

        void GetFastGCFunctions(FastGCFunctions* functions) override
        {
            fputs("CONTROL fast-functions\n", stderr);
            *functions = {};
            functions->context = this;
            functions->write_barrier = Mode("missing-post") ? nullptr : &PostStore;
            functions->pre_store = Mode("missing-pre") ? nullptr : &PreStore;
            functions->is_in_gc_heap = Mode("missing-heap") ? nullptr : &IsInHeap;
            functions->bulk_move_with_write_barrier = Mode("missing-move") ? nullptr : &Move;
            functions->bulk_clear_with_write_barrier =
                Mode("missing-clear") || Mode("obsolete-range-only") ? nullptr : &Clear;
            functions->reserved_pre_store_range = reinterpret_cast<void*>(&ObsoleteRange);
            functions->flags = Mode("unknown-flags") ? 0x80000000u : FASTGC_REQUIRES_OLD_VALUE;
        }
    };

    ControlHeap heap;
}

CONTROL_EXPORT void LOCALGC_CALLCONV GC_VersionInfo(VersionInfo* info)
{
    eeMajor = info->MajorVersion;
    eeMinor = info->MinorVersion;
    const char* major = getenv("SHARED_INTERFACE_MAJOR");
    const char* minor = getenv("SHARED_INTERFACE_MINOR");
    info->MajorVersion = major == nullptr ? 6 : static_cast<uint32_t>(strtoul(major, nullptr, 10));
    info->MinorVersion = minor == nullptr ? 8 : static_cast<uint32_t>(strtoul(minor, nullptr, 10));
    info->BuildVersion = 0;
    info->Name = "Shared write-barrier initialization control";
}

CONTROL_EXPORT HRESULT LOCALGC_CALLCONV GC_Initialize(
    IGCToCLR*, IGCHeap** result, IGCHandleManager** handles, GcDacVars*)
{
    fputs("CONTROL initialize\n", stderr);
    if (eeMajor != 6 || eeMinor < 1 || Mode("version-only"))
    {
        return E_FAIL;
    }
    *result = &heap;
    *handles = nullptr;
    return S_OK;
}
