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
#include "gcinterface.dac.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>

#if !defined(TARGET_UNIX) || !defined(HOST_AMD64) || !defined(FEATURE_NATIVEAOT) || defined(NDEBUG)
#error This Linux x64 control requires the assertion-enabled native sample interface defaults.
#endif

namespace
{
    class OldRuntime final : public IGCToCLR
    {
    public:
        bool reportedError = false;
        bool prefixOnly = false;

        bool GetBooleanConfigValue(const char*, const char*, bool*) override
        {
            assert(prefixOnly && "The old-host guard must precede configuration reads.");
            return false;
        }

        bool GetIntConfigValue(const char*, const char*, int64_t*) override
        {
            assert(prefixOnly && "The old-host guard must precede configuration reads.");
            return false;
        }

        bool GetStringConfigValue(const char*, const char*, const char** value) override
        {
            assert(prefixOnly && "The old-host guard must precede configuration reads.");
            *value = nullptr;
            return false;
        }

        uint32_t GetCurrentProcessCpuCount() override
        {
            assert(prefixOnly);
            return 1;
        }

        void GcScanCurrentStackRoots(promote_func*, ScanContext*) override
        {
            assert(!"The old-host guard must precede stack scanning.");
        }

        void GcPoll() override
        {
            assert(!"The old-host guard must precede polling.");
        }

        void LogErrorToHost(const char* message) override
        {
            reportedError = true;
            std::fprintf(stderr, "collector error: %s\n", message);
        }
    };

    struct LegacyFastGCFunctions
    {
        void* originalPrefix[5];
        void* preStoreRange;
        uint32_t flags;
    };

    struct GuardedLegacyBuffer
    {
        LegacyFastGCFunctions functions;
        std::array<uint8_t, 32> sentinel;
    };

    static_assert(sizeof(LegacyFastGCFunctions) == 56);
    static_assert(offsetof(GuardedLegacyBuffer, sentinel) == 56);
    static_assert(sizeof(GcDacVars) <= 4096);
}

int main(int argc, char** argv)
{
    if (argc != 2 && (argc != 3 || std::strcmp(argv[2], "--prefix-only") != 0))
    {
        std::fprintf(stderr, "Usage: shared-interface-old-host <collector.so> [--prefix-only]\n");
        return 2;
    }

    void* module = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (module == nullptr)
    {
        std::fprintf(stderr, "Could not load the collector: %s\n", dlerror());
        return 2;
    }
    GC_VersionInfoFunction versionInfo = reinterpret_cast<GC_VersionInfoFunction>(dlsym(module, "GC_VersionInfo"));
    GC_InitializeFunction initialize = reinterpret_cast<GC_InitializeFunction>(dlsym(module, "GC_Initialize"));
    if (versionInfo == nullptr || initialize == nullptr)
    {
        std::fprintf(stderr, "The collector does not export the shared initialization functions.\n");
        return 2;
    }

    GuardedLegacyBuffer buffer;
    std::memset(&buffer, 0xA5, sizeof(buffer));
    std::array<uint8_t, sizeof(buffer)> original;
    std::memcpy(original.data(), &buffer, sizeof(buffer));
    alignas(void*) std::array<uint8_t, 4096> dac;
    dac.fill(0x5A);
    std::array<uint8_t, 4096> originalDac = dac;
    IGCHeap* heap = reinterpret_cast<IGCHeap*>(static_cast<uintptr_t>(0x1234));
    IGCHandleManager* handles = reinterpret_cast<IGCHandleManager*>(static_cast<uintptr_t>(0x5678));
    IGCHeap* originalHeap = heap;
    IGCHandleManager* originalHandles = handles;
    VersionInfo version = {6, 0, 0, "EE 6.0 old-buffer control"};
    versionInfo(&version);
    std::printf("EE=6.0 collector=%u.%u old_buffer=%zu sentinel=%zu\n",
        version.MajorVersion, version.MinorVersion, sizeof(buffer.functions), buffer.sentinel.size());
    std::fflush(stdout);

    OldRuntime runtime;
    runtime.prefixOnly = argc == 3;
    if (runtime.prefixOnly && (version.MajorVersion != 6 || version.MinorVersion != 0))
    {
        std::fprintf(stderr, "FAIL: a prefix-only collector did not negotiate GC 6.0 for EE 6.0.\n");
        return 1;
    }
    HRESULT result = initialize(&runtime, &heap, &handles, reinterpret_cast<GcDacVars*>(dac.data()));
    if (runtime.prefixOnly)
    {
        if (result != S_OK || runtime.reportedError || heap == originalHeap || handles == originalHandles)
        {
            std::fprintf(stderr, "FAIL: prefix-only initialization failed after safe version negotiation.\n");
            return 1;
        }
        heap->GetFastGCFunctions(reinterpret_cast<FastGCFunctions*>(&buffer.functions));
        constexpr size_t PrefixBytes = 5 * sizeof(void*);
        if (std::memcmp(&buffer, original.data(), PrefixBytes) == 0 ||
            std::memcmp(reinterpret_cast<uint8_t*>(&buffer) + PrefixBytes,
                original.data() + PrefixBytes, sizeof(buffer) - PrefixBytes) != 0)
        {
            std::fprintf(stderr, "FAIL: a prefix-only writer changed the reserved tail or sentinel.\n");
            return 1;
        }
        std::puts("PASS: EE 6.0 negotiated GC 6.0 before initialization; no tail getter is eligible; five-field write preserved the old buffer tail and sentinel.");
        return 0;
    }
    if (result == S_OK)
    {
        // An old host accepts a higher collector minor and still passes its old output buffer.
        heap->GetFastGCFunctions(reinterpret_cast<FastGCFunctions*>(&buffer.functions));
        std::fprintf(stderr, "FAIL: the collector accepted EE 6.0 before the expanded-buffer call.\n");
        return 1;
    }
    if (result != static_cast<HRESULT>(E_FAIL) || !runtime.reportedError ||
        heap != originalHeap || handles != originalHandles || dac != originalDac ||
        std::memcmp(&buffer, original.data(), sizeof(buffer)) != 0)
    {
        std::fprintf(stderr, "FAIL: rejected initialization changed outputs or did not report its error.\n");
        return 1;
    }
    dlclose(module);
    std::puts("PASS: EE 6.0 rejected before initialization; old buffer, sentinel and outputs unchanged.");
    return 0;
}
