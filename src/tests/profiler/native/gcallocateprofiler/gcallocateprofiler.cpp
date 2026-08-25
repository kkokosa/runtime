// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "gcallocateprofiler.h"

#include <stdlib.h>

GUID GCAllocateProfiler::GetClsid()
{
    // {55b9554d-6115-45a2-be1e-c80f7fa35369}
	GUID clsid = { 0x55b9554d, 0x6115, 0x45a2,{ 0xbe, 0x1e, 0xc8, 0x0f, 0x7f, 0xa3, 0x53, 0x69 } };
	return clsid;
}

HRESULT GCAllocateProfiler::Initialize(IUnknown* pICorProfilerInfoUnk)
{
    Profiler::Initialize(pICorProfilerInfoUnk);

#if WIN32
    char* hookLibrary = nullptr;
    size_t hookLibraryLength = 0;
    _dupenv_s(&hookLibrary, &hookLibraryLength, "P14_NATIVE_HOOK_LIBRARY");
    if (hookLibrary != nullptr)
    {
        HMODULE module = LoadLibraryA(hookLibrary);
        free(hookLibrary);
        if (module == NULL)
        {
            printf("FAIL: unable to load allocation notification hooks\n");
            return E_FAIL;
        }

        _getAllocationNotificationCount =
            reinterpret_cast<GetAllocationNotificationCount>(GetProcAddress(
                module,
                "GC_AllocationNotificationTest_GetCount"));
        _getAllocationNotificationErrorCount =
            reinterpret_cast<GetAllocationNotificationCount>(GetProcAddress(
                module,
                "GC_AllocationNotificationTest_GetErrorCount"));
        _getAllocationNotificationObject =
            reinterpret_cast<GetAllocationNotificationObject>(GetProcAddress(
                module,
                "GC_AllocationNotificationTest_GetObject"));
        _resetAllocationNotifications =
            reinterpret_cast<ResetAllocationNotifications>(GetProcAddress(
                module,
                "GC_AllocationNotificationTest_Reset"));
        if ((_getAllocationNotificationCount == nullptr) ||
            (_getAllocationNotificationErrorCount == nullptr) ||
            (_getAllocationNotificationObject == nullptr) ||
            (_resetAllocationNotifications == nullptr))
        {
            printf("FAIL: unable to resolve allocation notification hooks\n");
            return E_FAIL;
        }

        _resetAllocationNotifications(nullptr, 0);
    }
#endif // WIN32

    HRESULT hr = S_OK;
    if (FAILED(hr = pCorProfilerInfo->SetEventMask2(COR_PRF_ENABLE_OBJECT_ALLOCATED, COR_PRF_HIGH_BASIC_GC | COR_PRF_HIGH_MONITOR_LARGEOBJECT_ALLOCATED | COR_PRF_HIGH_MONITOR_PINNEDOBJECT_ALLOCATED)))
    {
        printf("FAIL: ICorProfilerInfo::SetEventMask2() failed hr=0x%x", hr);
        return hr;
    }

    return S_OK;
}

HRESULT STDMETHODCALLTYPE GCAllocateProfiler::ObjectAllocated(ObjectID objectId, ClassID classId)
{
    COR_PRF_GC_GENERATION_RANGE gen;
    HRESULT hr = pCorProfilerInfo->GetObjectGeneration(objectId, &gen);
    if (FAILED(hr))
    {
        printf("GetObjectGeneration failed hr=0x%x\n", hr);
        _failures++;
    }
    uint32_t expectedAllocationFlag = 0;
    if (SUCCEEDED(hr) && gen.generation == COR_PRF_GC_LARGE_OBJECT_HEAP)
    {
        expectedAllocationFlag = 1 << 2;
        _gcLOHAllocations++;
    }
    else if (SUCCEEDED(hr) && gen.generation == COR_PRF_GC_PINNED_OBJECT_HEAP)
    {
        expectedAllocationFlag = 1 << 3;
        _gcPOHAllocations++;
    }
    else if (SUCCEEDED(hr))
    {
        printf("Unexpected object allocation captured, gen.generation=0x%x\n", gen.generation);
        _failures++;
    }

    if ((_getAllocationNotificationCount != nullptr) && (expectedAllocationFlag != 0))
    {
        int64_t count = _getAllocationNotificationCount();
        bool found = false;
        for (int64_t index = count; index > 0; index--)
        {
            if (_getAllocationNotificationObject(index - 1) == reinterpret_cast<void*>(objectId))
            {
                found = true;
                break;
            }
        }

        int64_t errors = _getAllocationNotificationErrorCount();
        if (!found || (errors != 0))
        {
            printf(
                "Allocation profiler callback preceded the allocation-complete callback "
                "(count=%lld, errors=%lld, expected=0x%x)\n",
                (long long)count,
                (long long)errors,
                expectedAllocationFlag);
            _failures++;
        }
    }

    return S_OK;
}

HRESULT GCAllocateProfiler::Shutdown()
{
    Profiler::Shutdown();
    if (_gcPOHAllocations == 0)
    {
        printf("There is no POH allocations\n");
    }
    else if (_gcLOHAllocations == 0)
    {
        printf("There is no LOH allocations\n");
    }
    else if (_failures == 0)
    {
        printf("%d LOH objects allocated\n", (int)_gcLOHAllocations);
        printf("%d POH objects allocated\n", (int)_gcPOHAllocations);
        printf("PROFILER TEST PASSES\n");
    }
    fflush(stdout);

    return S_OK;
}
