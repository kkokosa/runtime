// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <vector>

#define HOST_64BIT
#define DPTR(type) type*
#define FORCEINLINE inline
#define _ASSERTE assert
using PTR_size_t = size_t*;
using PTR_uint8_t = uint8_t*;
using BOOL = int;

class MethodTable
{
public:
    size_t baseSize;
    size_t componentSize;
    bool references;
    bool ContainsGCPointers() const { return references; }
    bool HasComponentSize() const { return componentSize != 0; }
    size_t GetBaseSize() const { return baseSize; }
    size_t RawGetComponentSize() const { return componentSize; }
    bool Collectible() const { return false; }
};

struct ObjHeader { uintptr_t value; };
class Object
{
public:
    MethodTable* type;
    MethodTable* GetGCSafeMethodTable() const { return type; }
};
class ArrayBase : public Object
{
public:
    uint32_t count;
    uint32_t padding;
    uint32_t GetNumComponents() const { return count; }
};

#include "../../../../src/coreclr/gc/gcref.h"

namespace
{
    struct Layout
    {
        alignas(8) uint8_t descriptor[128]{};
        MethodTable type{};
    };

    bool CheckRange(Object* object, size_t offset, size_t bytes, size_t maximumYieldedRanges,
        bool restrictToRange = true)
    {
        uintptr_t begin = reinterpret_cast<uintptr_t>(object) + offset;
        uintptr_t end = begin + bytes;
        std::vector<uintptr_t> expected;
        GCReferenceRanges::Enumerate(object, [&](Object** first, size_t count)
        {
            for (size_t index = 0; index < count; index++)
            {
                uintptr_t address = reinterpret_cast<uintptr_t>(first + index);
                if (address >= begin && address + sizeof(Object*) <= end)
                {
                    expected.push_back(address);
                }
            }
            return true;
        });

        GCReferenceRangeIterator iterator(object);
        if (restrictToRange)
        {
#ifndef LXR_RANGE_TEST_BASELINE
            iterator.RestrictToRange(offset, bytes);
#endif
        }
        GCReferenceRange range{};
        std::vector<uintptr_t> actual;
        size_t yieldedRanges = 0;
        while (iterator.Next(&range))
        {
            yieldedRanges++;
            for (size_t index = 0; index < range.count; index++)
            {
                uintptr_t address = reinterpret_cast<uintptr_t>(range.start + index);
                if (address < begin || address + sizeof(Object*) > end)
                {
                    std::printf("FAIL iterator returned a slot outside offset=%zu bytes=%zu\n",
                        offset, bytes);
                    return false;
                }
                actual.push_back(address);
            }
        }
        std::sort(expected.begin(), expected.end());
        std::sort(actual.begin(), actual.end());
        if (actual != expected || yieldedRanges > maximumYieldedRanges)
        {
            std::printf("FAIL offset=%zu bytes=%zu expected=%zu actual=%zu yielded_ranges=%zu bound=%zu\n",
                offset, bytes, expected.size(), actual.size(), yieldedRanges, maximumYieldedRanges);
            return false;
        }
        return true;
    }
}

int main()
{
    Layout mixed{};
    mixed.type = {24, 24, true};
    CGCDesc::InitValueClassSeries(&mixed.type, 2);
    CGCDescSeries* series = CGCDesc::GetCGCDescFromMT(&mixed.type)->GetHighestSeries();
    series->SetSeriesOffset(16);
    series->val_serie[0].set_val_serie_item(1, 8);
    series->val_serie[-1].set_val_serie_item(1, 0);

    constexpr uint32_t Count = 23;
    std::vector<uintptr_t> storage((24 + Count * 24) / sizeof(uintptr_t));
    ArrayBase* array = reinterpret_cast<ArrayBase*>(storage.data() + 1);
    array->type = &mixed.type;
    array->count = Count;
    if (!CheckRange(array, 0, 16 + Count * 24, 2 * Count, false))
    {
        return 4;
    }
    for (size_t offset = 8; offset <= 16 + Count * 24; offset += 8)
    {
        for (size_t bytes = 0; bytes <= 16 + Count * 24 - offset; bytes += 8)
        {
            if (!CheckRange(array, offset, bytes, 2 * (bytes / 24 + 2)))
            {
                return 1;
            }
        }
    }
    for (size_t offset = 8; offset < 16 + Count * 24; offset++)
    {
        size_t maximum = std::min<size_t>(48, 16 + Count * 24 - offset);
        for (size_t bytes = 0; bytes <= maximum; bytes++)
        {
            if (!CheckRange(array, offset, bytes, 2 * (bytes / 24 + 2)))
            {
                return 5;
            }
        }
    }

    constexpr uint32_t LargeCount = 1000000;
    storage.resize((24 + LargeCount * 24) / sizeof(uintptr_t));
    array = reinterpret_cast<ArrayBase*>(storage.data() + 1);
    array->type = &mixed.type;
    array->count = LargeCount;
    if (!CheckRange(array, 16 + (LargeCount - 2) * 24, 24, 4))
    {
        return 2;
    }

    Layout ordinary{};
    ordinary.type = {48, 0, true};
    CGCDesc::Init(&ordinary.type, 2);
    series = CGCDesc::GetCGCDescFromMT(&ordinary.type)->GetHighestSeries();
    series->SetSeriesOffset(8);
    series->SetSeriesSize(sizeof(Object*) - ordinary.type.baseSize);
    (series - 1)->SetSeriesOffset(32);
    (series - 1)->SetSeriesSize(sizeof(Object*) - ordinary.type.baseSize);
    storage.resize(ordinary.type.baseSize / sizeof(uintptr_t));
    Object* object = reinterpret_cast<Object*>(storage.data() + 1);
    object->type = &ordinary.type;
    if (!CheckRange(object, 0, 40, 2, false))
    {
        return 6;
    }
    for (size_t offset = 8; offset <= 40; offset += 8)
    {
        for (size_t bytes = 0; bytes <= 40 - offset; bytes += 8)
        {
            if (!CheckRange(object, offset, bytes, 2))
            {
                return 3;
            }
        }
    }
    for (size_t offset = 0; offset <= 40; offset++)
    {
        for (size_t bytes = 0; bytes <= 40 - offset; bytes++)
        {
            if (!CheckRange(object, offset, bytes, 2))
            {
                return 7;
            }
        }
    }
    std::puts("PASS ordinary and repeating partial ranges; late-array case yields at most four ranges (not an internal work count)");
    return 0;
}
