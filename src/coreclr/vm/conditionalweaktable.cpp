// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
//

#include "conditionalweaktable.h"

bool ConditionalWeakTableContainerObject::TryGetValue(OBJECTREF key, OBJECTREF* value)
{
    CONTRACTL
    {
        NOTHROW;
        GC_NOTRIGGER;
        MODE_ANY;
    }
    CONTRACTL_END;
    SUPPORTS_DAC;
    _ASSERTE(key != nullptr && value != nullptr);

    INT32 hashCode = key->TryGetHashCode();

    if (hashCode == 0)
    {
        *value = nullptr;
        return false;
    }

    hashCode &= INT32_MAX;
    int bucket = hashCode & (_buckets->GetNumComponents() - 1);
    PTR_int32_t buckets = _buckets->GetDirectPointerToNonObjectElements();
    DPTR(Entry) entries = _entries->GetDirectPointerToNonObjectElements();

    for (int entriesIndex = buckets[bucket]; entriesIndex != -1; entriesIndex = entries[entriesIndex].Next)
    {
        const Entry& entry = entries[entriesIndex];
        if (entry.HashCode != hashCode)
        {
            continue;
        }

        // The key and the value are raw pointers: they are only described by the entries array's
        // ephemeron registration, never by its GC descriptor. Reading them is safe here because
        // this only runs while the runtime is suspended or out of process, so the GC cannot be
        // severing or relocating a pair underneath us.
        PTR_Object entryKey = dac_cast<PTR_Object>(entry.Pair.Key);

        if ((entryKey != NULL) && (ObjectToOBJECTREF(entryKey) == key))
        {
            *value = ObjectToOBJECTREF(dac_cast<PTR_Object>(entry.Pair.Value));
            return true;
        }
    }

    *value = nullptr;
    return false;
}
