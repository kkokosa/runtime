// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.Diagnostics.DataContractReader.Contracts;

/// <summary>
/// ConditionalWeakTable contract version 2.
/// </summary>
/// <remarks>
/// Differs from version 1 in how an entry stores its key/value pair. In version 1 <c>depHnd</c> was a
/// native <c>OBJECTHANDLE</c> whose target was the key and whose handle extra info was the value. In
/// version 2 the entry holds the pair itself: <c>Pair</c> is the key immediately followed by the
/// value, as raw object pointers that the GC only traces through the container's ephemeron array
/// registration. As a result this version no longer uses the <c>GC</c> contract.
/// </remarks>
internal struct ConditionalWeakTable_2 : IConditionalWeakTable
{
    private readonly Target _target;

    internal ConditionalWeakTable_2(Target target)
    {
        _target = target;
    }

    bool IConditionalWeakTable.TryGetValue(TargetPointer conditionalWeakTable, TargetPointer key, out TargetPointer value)
    {
        value = TargetPointer.Null;

        // Read _container from the CWT object and _buckets/_entries from the Container.
        Data.ConditionalWeakTable cwt = _target.ProcessedData.GetOrAdd<Data.ConditionalWeakTable>(conditionalWeakTable);
        Data.ConditionalWeakTableContainer container = _target.ProcessedData.GetOrAdd<Data.ConditionalWeakTableContainer>(cwt.Container);

        int hashCode = _target.Contracts.Object.TryGetHashCode(key);
        if (hashCode == 0)
            return false;

        hashCode &= int.MaxValue;

        Data.Array bucketsArray = _target.ProcessedData.GetOrAdd<Data.Array>(container.Buckets);
        uint bucketCount = bucketsArray.NumComponents;

        int bucket = hashCode & (int)(bucketCount - 1);
        int entriesIndex = _target.Read<int>(bucketsArray.DataPointer + (ulong)(bucket * sizeof(int)));

        Data.Array entriesArray = _target.ProcessedData.GetOrAdd<Data.Array>(container.Entries);
        TargetPointer entriesMT = _target.Contracts.Object.GetMethodTableAddress(container.Entries);
        ITypeHandle entriesTypeHandle = _target.Contracts.RuntimeTypeSystem.GetTypeHandle(entriesMT);
        uint entrySize = _target.Contracts.RuntimeTypeSystem.GetComponentSize(entriesTypeHandle);

        while (entriesIndex != -1)
        {
            TargetPointer entryAddress = entriesArray.DataPointer + (ulong)((uint)entriesIndex * entrySize);
            Data.ConditionalWeakTableEntry entry = _target.ProcessedData.GetOrAdd<Data.ConditionalWeakTableEntry>(entryAddress);

            if (entry.HashCode == hashCode)
            {
                // The pair is the key immediately followed by the value.
                TargetPointer pair = entry.PairAddress!.Value;
                if (_target.ReadPointer(pair) == key)
                {
                    value = _target.ReadPointer(pair + (uint)_target.PointerSize);

                    return true;
                }
            }

            entriesIndex = entry.Next;
        }

        return false;
    }
}
