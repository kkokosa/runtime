// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
//
// File: ephemeronarray.cpp
//

//
// FCalls for System.Runtime.EphemeronArray
//

#include "common.h"
#include "ephemeronarray.h"
#include "gcheaputilities.h"

FCIMPL2(void*, EphemeronArrayNative::Register, ArrayBase* array, INT32 pairOffset)
{
    FCALL_CONTRACT;

    _ASSERTE(array != NULL);

    MethodTable* pArrayMT = array->GetMethodTable();

    // If the element type described any object references the GC would trace the key and the value
    // strongly, which would keep every value - and through it every key it references - alive
    // forever. The managed side only ever registers arrays of types that store the pair as raw
    // pointers, so this is an invariant rather than a user error.
    _ASSERTE(pArrayMT->IsArray());
    _ASSERTE(!pArrayMT->ContainsGCPointers());
    _ASSERTE(pArrayMT->GetRank() == 1);

    if (!pArrayMT->IsArray() || pArrayMT->ContainsGCPointers())
    {
        return NULL;
    }

    SIZE_T stride = pArrayMT->GetComponentSize();
    SIZE_T dataOffset = ArrayBase::GetDataPtrOffset(pArrayMT);

    // A pair is a key pointer immediately followed by a value pointer, so it has to fit in an
    // element at the requested offset.
    _ASSERTE(pairOffset >= 0);
    _ASSERTE(((SIZE_T)pairOffset + (2 * sizeof(void*))) <= stride);

    if ((pairOffset < 0) || (((SIZE_T)pairOffset + (2 * sizeof(void*))) > stride))
    {
        return NULL;
    }

    dataOffset += (SIZE_T)pairOffset;

    // Both of these are bounded by the array header size plus one element, so they always fit. The
    // GC stores them as 32 bit values to keep a registration small.
    _ASSERTE(FitsIn<uint32_t>(dataOffset));
    _ASSERTE(FitsIn<uint32_t>(stride));

    return GCHeapUtilities::GetGCHeap()->RegisterEphemeronArray(
        (Object*)array,
        (uint32_t)dataOffset,
        (uint32_t)stride,
        (uint32_t)array->GetNumComponents());
}
FCIMPLEND

FCIMPL2(void, EphemeronArrayNative::Unregister, ArrayBase* array, void* registration)
{
    FCALL_CONTRACT;

    _ASSERTE(array != NULL);
    _ASSERTE(registration != NULL);

    GCHeapUtilities::GetGCHeap()->UnregisterEphemeronArray((Object*)array, (uint8_t*)registration);
}
FCIMPLEND
