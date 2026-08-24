# Contract ConditionalWeakTable

This contract provides the ability to look up values in a `ConditionalWeakTable<TKey, TValue>` managed object by key identity.

## APIs of contract

``` csharp
// Try to find the value associated with the given key in the conditional weak table.
// Returns true and sets value if found, false otherwise.
bool TryGetValue(TargetPointer conditionalWeakTable, TargetPointer key, out TargetPointer value);
```

## Version 1

This contract reads the field layout of `ConditionalWeakTable<TKey, TValue>` and its nested types
(`Container`, `Container+Entry`) via the [`ManagedTypeSource`](ManagedTypeSource.md) contract rather
than cDAC data descriptors. Most field offsets are resolved by name at runtime.

<!-- BEGIN GENERATED: usage contract=ConditionalWeakTable version=c1 -->
### Data descriptors used

| Data Descriptor | Field | Type | Meaning |
| --- | --- | --- | --- |
| `Array` | *(type size)* | `uint32` | Size of the fixed portion of an array object |
| `Array` | `m_NumComponents` | `uint32` | Number of items in the array |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2`` | `_container` | `pointer` | Active container that owns the table's buckets and entries |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Container`` | `_buckets` | `pointer` | Array of entry indexes at the head of each hash bucket; -1 denotes an empty bucket |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Container`` | `_entries` | `pointer` | Array containing the table's ephemeron pairs and hash-chain links |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `depHnd` | `pointer` | Dependent handle that weakly references the key and conditionally keeps the value alive |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `HashCode` | `int32` | Cached nonnegative identity hash code of the entry's key; -1 denotes a removed entry |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `Next` | `int32` | Index of the next entry in the hash bucket chain, or -1 for the end |

### Global variables used

_None._

### Contracts used

| Contract Name |
| --- |
| `GC` |
| `Object` |
| `RuntimeTypeSystem` |
<!-- END GENERATED: usage contract=ConditionalWeakTable version=c1 -->


The algorithm looks up the `_container` field of the `ConditionalWeakTable` object, then reads the
`_buckets` and `_entries` fields from the container. It resolves `Entry` field offsets (`HashCode`,
`Next`, `depHnd`) via `ManagedTypeSource` and determines the entry stride from the entries array's
component size.

``` csharp
bool TryGetValue(TargetPointer conditionalWeakTable, TargetPointer key, out TargetPointer value)
{
    value = TargetPointer.Null;

    // Resolve field offsets by name via ManagedTypeSource.
    IRuntimeTypeSystem rts = target.Contracts.RuntimeTypeSystem;
    IManagedTypeSource mts = target.Contracts.ManagedTypeSource;
    Target.TypeInfo cwtType = mts.GetTypeInfo("System.Runtime.CompilerServices.ConditionalWeakTable`2");
    Target.TypeInfo containerType = mts.GetTypeInfo("System.Runtime.CompilerServices.ConditionalWeakTable`2+Container");
    Target.TypeInfo entryType = mts.GetTypeInfo("System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry");

    uint containerOffset = (uint)cwtType.Fields["_container"].Offset;
    uint bucketsOffset   = (uint)containerType.Fields["_buckets"].Offset;
    uint entriesOffset   = (uint)containerType.Fields["_entries"].Offset;
    uint hashCodeOffset  = (uint)entryType.Fields["HashCode"].Offset;
    uint nextOffset      = (uint)entryType.Fields["Next"].Offset;
    uint depHndOffset    = (uint)entryType.Fields["depHnd"].Offset;

    // Navigate from the ConditionalWeakTable object to its container
    TargetPointer container = target.ReadPointer(conditionalWeakTable + /* Object data offset */ + containerOffset);

    // Read the container's buckets and entries array pointers
    TargetPointer bucketsPtr = target.ReadPointer(container + /* Object data offset */ + bucketsOffset);
    TargetPointer entriesPtr = target.ReadPointer(container + /* Object data offset */ + entriesOffset);

    // Get the runtime default hash code for the key object (returns 0 if none assigned)
    int hashCode = target.Contracts.Object.TryGetHashCode(key);
    if (hashCode == 0)
        return false;

    hashCode &= int.MaxValue;

    // Read the buckets array length and find the bucket (bucketCount is a power of 2)
    uint bucketCount = target.Read<uint>(bucketsPtr + /* Array::m_NumComponents offset */);
    int bucket = hashCode & (int)(bucketCount - 1);
    int entriesIndex = target.Read<int>(bucketsPtr + /* Array header size */ + bucket * sizeof(int));

    // Get entry size from the entries array's component size
    TargetPointer entriesMT = target.Contracts.Object.GetMethodTableAddress(entriesPtr);
    uint entrySize = rts.GetComponentSize(rts.GetTypeHandle(entriesMT));

    // Walk the chain
    while (entriesIndex != -1)
    {
        TargetPointer entryAddr = entriesPtr + /* Array header size */ + (uint)entriesIndex * entrySize;
        int entryHashCode = target.Read<int>(entryAddr + hashCodeOffset);

        if (entryHashCode == hashCode)
        {
            // depHnd is an OBJECTHANDLE — a pointer to a pointer to the object
            TargetPointer depHnd = target.ReadPointer(entryAddr + depHndOffset);
            TargetPointer handleTarget = target.ReadPointer(depHnd);
            if (handleTarget == key)
            {
                value = target.Contracts.GC.GetHandleExtraInfo(depHnd);
                return true;
            }
        }

        entriesIndex = target.Read<int>(entryAddr + nextOffset);
    }

    return false;
}
```

## Version 2

Identical to version 1 except for how an entry stores its key and value.

In version 1, `depHnd` is a native `OBJECTHANDLE` for a dependent handle: the handle's object is the
key and the handle's extra info is the value. In version 2 the entry holds the pair itself, in a
`Pair` field that is the key immediately followed by the value. Both are raw object pointers, and
either is null when the entry is unused, has been removed, or has had its key collected.

The pairs of a whole container live in its one `_entries` array, which the runtime registers with
the GC as an ephemeron array. That registration - rather than the array's GC descriptor - is what
gives the pairs their conditional lifetime, which is why nothing about them is reachable through the
handle table any more.

As a result this version no longer uses the [`GC`](GC.md) contract.

<!-- BEGIN GENERATED: usage contract=ConditionalWeakTable version=c2 -->
### Data descriptors used

| Data Descriptor | Field | Type | Meaning |
| --- | --- | --- | --- |
| `Array` | *(type size)* | `uint32` | Size of the fixed portion of an array object |
| `Array` | `m_NumComponents` | `uint32` | Number of items in the array |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2`` | `_container` | `pointer` | Active container that owns the table's buckets and entries |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Container`` | `_buckets` | `pointer` | Array of entry indexes at the head of each hash bucket; -1 denotes an empty bucket |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Container`` | `_entries` | `pointer` | Array containing the table's ephemeron pairs and hash-chain links |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `HashCode` | `int32` | Cached nonnegative identity hash code of the entry's key; -1 denotes a removed entry |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `Next` | `int32` | Index of the next entry in the hash bucket chain, or -1 for the end |
| ``System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry`` | `Pair` | `pointer` | Inline ephemeron key/value pair whose value is conditionally kept alive while its key is reachable |

### Global variables used

_None._

### Contracts used

| Contract Name |
| --- |
| `Object` |
| `RuntimeTypeSystem` |
<!-- END GENERATED: usage contract=ConditionalWeakTable version=c2 -->

Only the body of the chain walk differs from version 1:

``` csharp
    while (entriesIndex != -1)
    {
        TargetPointer entryAddr = entriesPtr + /* Array header size */ + (uint)entriesIndex * entrySize;
        int entryHashCode = target.Read<int>(entryAddr + hashCodeOffset);

        if (entryHashCode == hashCode)
        {
            // The pair is the key immediately followed by the value.
            TargetPointer pair = entryAddr + pairOffset;
            if (target.ReadPointer(pair) == key)
            {
                value = target.ReadPointer(pair + target.PointerSize);
                return true;
            }
        }

        entriesIndex = target.Read<int>(entryAddr + nextOffset);
    }
```
