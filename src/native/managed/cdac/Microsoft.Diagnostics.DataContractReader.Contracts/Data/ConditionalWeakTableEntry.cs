// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace Microsoft.Diagnostics.DataContractReader.Data;

[CdacType("System.Runtime.CompilerServices.ConditionalWeakTable`2+Entry")]
internal sealed partial class ConditionalWeakTableEntry : IData<ConditionalWeakTableEntry>
{
    [Field("HashCode")]
    public partial int HashCode { get; }

    [Field("Next")]
    public partial int Next { get; }

    // Descriptor-optional: only present in ConditionalWeakTable contract version 1, where an entry
    // holds a native OBJECTHANDLE for a dependent handle.
    [FieldAddress("depHnd")]
    public partial TargetPointer? DepHndAddress { get; }

    // Descriptor-optional: only present in ConditionalWeakTable contract version 2 and later, where
    // an entry holds the key and the value directly as an ephemeron pair - the key followed by the
    // value - inside the container's registered entries array.
    [FieldAddress("Pair")]
    public partial TargetPointer? PairAddress { get; }
}
