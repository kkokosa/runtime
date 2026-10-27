// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Buffers.Binary;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

internal static partial class Program
{
    private delegate void SharedBulkClear(ref byte destination, nuint byteCount);

    private const int BarrierLargeBytes = 32792;

    private sealed class InterpreterBarrierBox
    {
        internal object? Value;
    }

    private static object? s_interpreterBarrierValue;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void InterpretedStoreField(InterpreterBarrierBox target, object? value) => target.Value = value;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void InterpretedStoreStatic(object? value) => s_interpreterBarrierValue = value;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void InterpretedStoreElement(object?[] target, object? value) => target[0] = value;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void InterpretedStoreIndirect(ref object? target, object? value) => target = value;

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void InterpretedStoreStruct(ref BarrierMixed target, BarrierMixed value) => target = value;

    private static void VerifyInterpretedSharedStores(nint module, GetMetric metric, Collect collect)
    {
        bool counters = Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics") == "1";
        if (counters)
        {
            EnableStorage enable = Marshal.GetDelegateForFunctionPointer<EnableStorage>(
                NativeLibrary.GetExport(module, "GC_LxrPrototype_EnableStorageDiagnostics"));
            Check(enable() == 0, "Could not enable interpreter store diagnostics.");
        }

        void Measure(string name, Action restore, Action write, ulong references)
        {
            write();
            restore();
            Check(collect(1) == 0 && collect(1) == 0, $"{name}: epoch setup failed.");
            ulong logs = counters ? metric(462) : 0;
            ulong old = counters ? metric(463) : 0;
            ulong collections = metric(5);
            write();
            ulong logged = counters ? metric(462) - logs : 0;
            ulong checkedOld = counters ? metric(463) - old : 0;
            Check(metric(5) == collections, $"{name}: a collection occurred during the store.");
            if (counters)
            {
                Check(logged == references && checkedOld == references,
                    $"{name}: logged={logged}, old={checkedOld}, expected={references}.");
                Console.WriteLine($"interpreter_store name={name} logged={logged} old_targets={checkedOld}");
            }
            Console.WriteLine($"PASS interpreter store {name}; mode={(counters ? "metrics" : "behavior-only")}");
        }

        object oldValue = new Node(137);
        object proposed = new Node(139);
        InterpreterBarrierBox box = new() { Value = oldValue };
        object?[] slots = [oldValue];
        BarrierMixed[] values = [new() { First = oldValue, Number = 41, Last = oldValue }];
        Measure("stfld", () => box.Value = oldValue, () => InterpretedStoreField(box, null), 1);
        Check(box.Value is null, "The interpreted field store was lost.");
        Measure("stsfld", () => s_interpreterBarrierValue = oldValue, () => InterpretedStoreStatic(null), 1);
        Check(s_interpreterBarrierValue is null, "The interpreted static store was lost.");
        Measure("stelem.ref", () => slots[0] = oldValue, () => InterpretedStoreElement(slots, null), 1);
        Check(slots[0] is null, "The interpreted array-element store was lost.");
        Measure("stind.ref", () => slots[0] = oldValue,
            () => InterpretedStoreIndirect(ref slots[0], "interpreter literal"), 1);
        Check(ReferenceEquals(slots[0], "interpreter literal"), "The interpreted indirect store was lost.");
        Measure("stobj", () => values[0] = new() { First = oldValue, Number = 41, Last = oldValue },
            () => InterpretedStoreStruct(ref values[0],
                new() { First = proposed, Number = 127, Last = null }), 2);
        Check(ReferenceEquals(values[0].First, proposed) && values[0].Number == 127 && values[0].Last is null,
            "The interpreted reference-containing struct store was lost.");
        GC.KeepAlive(oldValue);
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct BarrierMixed
    {
        [FieldOffset(0)]
        internal object? First;
        [FieldOffset(8)]
        internal long Number;
        [FieldOffset(16)]
        internal object? Last;
    }

    [StructLayout(LayoutKind.Explicit, Size = BarrierLargeBytes)]
    private struct BarrierLarge
    {
        [FieldOffset(0)]
        internal object? First;
        [FieldOffset(8)]
        internal long Number;
        [FieldOffset(16)]
        internal object? Last;
    }

    [StructLayout(LayoutKind.Explicit, Size = BarrierLargeBytes)]
    private struct BarrierClearRange
    {
        [FieldOffset(BarrierLargeBytes - 8)]
        internal object? Last;
    }

    [StructLayout(LayoutKind.Explicit)]
    private sealed class BarrierBox
    {
        [FieldOffset(0)]
        internal long Prefix = 17;
        [FieldOffset(8)]
        internal BarrierLarge Value;
        [FieldOffset(8 + BarrierLargeBytes)]
        internal long Suffix = 29;
    }

    private static void VerifySharedBarrierBehavior()
    {
        Check(Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics") != "1",
            "The stock/Satori behavior control does not provide LXR callback metrics.");
        VerifySharedWriteBarriers(0,
            metric => metric == 5
                ? (ulong)GC.CollectionCount(0) + (ulong)GC.CollectionCount(1) + (ulong)GC.CollectionCount(2)
                : throw new InvalidOperationException("The behavior control requested an unsupported metric."),
            _ =>
            {
                GC.Collect();
                return 0;
            });
    }

    private static uint GetSharedBulkChunk()
    {
        MethodInfo dispatch = typeof(Buffer).GetMethod(
            "BulkMoveWithWriteBarrier", BindingFlags.NonPublic | BindingFlags.Static) ??
            throw new InvalidOperationException("The runtime has no shared bulk dispatch.");
        byte[] il = dispatch.GetMethodBody()?.GetILAsByteArray() ??
            throw new InvalidOperationException("The shared bulk dispatch has no inspectable IL.");
        int start = 0;
        while (start < il.Length && il[start] == OpCodes.Nop.Value)
        {
            start++;
        }
        // CoreLib removes literal fields. Read the bound from its byte-count comparison instead.
        Check(il.Length - start >= 8 &&
            il[start] == OpCodes.Ldarg_2.Value && il[start + 1] == OpCodes.Ldc_I4.Value &&
            (il[start + 6] == OpCodes.Conv_I.Value || il[start + 6] == OpCodes.Conv_U.Value) &&
            (il[start + 7] == OpCodes.Bgt_Un_S.Value || il[start + 7] == OpCodes.Bgt_Un.Value),
            "The runtime bulk chunk comparison has an unknown IL shape.");
        uint chunk = BinaryPrimitives.ReadUInt32LittleEndian(il.AsSpan(start + 2, sizeof(uint)));
        Check(chunk != 0 && chunk % (uint)IntPtr.Size == 0, "The runtime bulk chunk bound is invalid.");
        return chunk;
    }

    private static void VerifySharedWriteBarriers(nint module, GetMetric metric, Collect collect)
    {
        bool counters = Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics") == "1";
        ulong chunkBytes = GetSharedBulkChunk();
        Console.WriteLine($"shared_barrier_mode={(counters ? "metrics" : "behavior-only")} chunk_bytes={chunkBytes}");
        Console.WriteLine($"shared_barrier_layout mixed_bytes={Unsafe.SizeOf<BarrierMixed>()} " +
            $"large_bytes={Unsafe.SizeOf<BarrierLarge>()}");
        Check(Unsafe.SizeOf<BarrierMixed>() == 24 && Unsafe.SizeOf<BarrierLarge>() == BarrierLargeBytes &&
            (ulong)BarrierLargeBytes > 2 * chunkBytes,
            "The test layouts do not exercise mixed references and multi-chunk partial-object writes.");
        if (counters)
        {
            EnableStorage enable = Marshal.GetDelegateForFunctionPointer<EnableStorage>(
                NativeLibrary.GetExport(module, "GC_LxrPrototype_EnableStorageDiagnostics"));
            Check(enable() == 0, "Could not enable shared-barrier diagnostics.");
        }

        void Rearm()
        {
            Check(collect(1) == 0 && collect(1) == 0, "Shared-barrier setup pauses failed.");
        }

        static void CheckCleared(BarrierMixed[] values, string name)
        {
            string failure = $"{name}: a reference or numeric field was not cleared.";
            foreach (BarrierMixed element in values)
            {
                Check(element.First is null && element.Last is null && element.Number == 0,
                    failure);
            }
        }

        void Measure(string name, Action write, ulong references, ulong oldTargets,
            ulong byteCount = 0, bool noUnloggedSlots = false, bool bulk = false, bool clear = false,
            uint destinationAlignment = 0)
        {
            ulong logs = counters ? metric(462) : 0;
            ulong checks = counters ? metric(463) : 0;
            ulong callbacks = counters ? metric(clear ? 465u : 464u) : 0;
            ulong lookups = counters ? metric(466) : 0;
            ulong earlyOuts = counters ? metric(467) : 0;
            ulong collections = metric(5);
            write();
            ulong logsAfter = counters ? metric(462) : 0;
            ulong checksAfter = counters ? metric(463) : 0;
            ulong lookupsAfter = counters ? metric(466) : 0;
            ulong earlyOutsAfter = counters ? metric(467) : 0;
            Check(metric(5) == collections, $"{name}: a collection invalidated the exact measurement.");
            if (counters)
            {
                Check(logsAfter - logs == references,
                    $"{name}: first writes {logsAfter - logs}, expected {references}.");
                Check(checksAfter - checks == oldTargets,
                    $"{name}: old targets {checksAfter - checks}, expected {oldTargets}.");
                if (bulk || noUnloggedSlots)
                {
                    Check((clear || byteCount != 0) && destinationAlignment < IntPtr.Size &&
                        (clear || destinationAlignment == 0), $"{name}: invalid bulk count or alignment.");
                    // A long unaligned clear shortens its first chunk to align later chunk boundaries.
                    ulong expectedCallbacks = byteCount == 0 ? 0 : byteCount <= chunkBytes ? 1 :
                        1 + (byteCount - (chunkBytes - destinationAlignment) + chunkBytes - 1) / chunkBytes;
                    Check(metric(clear ? 465u : 464u) - callbacks == expectedCallbacks,
                        $"{name}: expected one shared callback per bounded byte chunk.");
                }
                if (noUnloggedSlots)
                {
                    Check(lookupsAfter == lookups && earlyOutsAfter > earlyOuts,
                        $"{name}: a range with no unlogged slots required a layout lookup.");
                }
                else if (bulk && byteCount != 0)
                {
                    Check(lookupsAfter > lookups, $"{name}: old storage did not validate its containing layout.");
                }
                Console.WriteLine($"shared_barrier_counts name={name} logged={logsAfter - logs} " +
                    $"old_targets={checksAfter - checks} callbacks={metric(clear ? 465u : 464u) - callbacks} " +
                    $"layout_lookups={lookupsAfter - lookups} metadata_early_outs={earlyOutsAfter - earlyOuts}");
            }
            Console.WriteLine($"PASS shared-barrier {name}");
        }

        object old = new Node(71);
        object proposed = new Node(73);
        object mismatch = new Node(79);
        object?[] slot = [old];
        Rearm();
        Measure("scalar null", () => slot[0] = null, 1, 1);
        Check(slot[0] is null, "The scalar null store was lost.");
        Measure("same epoch", () => slot[0] = old, 0, 0);
        Rearm();
        Measure("scalar literal", () => slot[0] = "shared-barrier literal", 1, 1);
        Check(slot[0] is string, "The literal store was lost.");
        slot[0] = old;
        Rearm();
        Measure("scalar new object", () => slot[0] = new Node(83), 1, 1);
        Check(slot[0] is Node { Value: 83 }, "The new-object store was lost.");
        slot[0] = old;
        Rearm();
        Measure("exchange null", () => Check(ReferenceEquals(Interlocked.Exchange(ref slot[0], null), old),
            "Exchange returned the wrong old value."), 1, 1);
        slot[0] = old;
        Rearm();
        Measure("failed CAS null", () => Check(
            ReferenceEquals(Interlocked.CompareExchange(ref slot[0], null, mismatch), old),
            "Failed CAS returned the wrong value."), 1, 1);
        Check(ReferenceEquals(slot[0], old), "Failed CAS committed its proposed null.");
        Rearm();
        Measure("failed CAS heap value", () => Check(
            ReferenceEquals(Interlocked.CompareExchange(ref slot[0], proposed, mismatch), old),
            "Failed CAS returned the wrong value."), 1, 1);
        Check(ReferenceEquals(slot[0], old), "Failed CAS committed its proposed heap value.");
        slot[0] = null;
        Rearm();
        Measure("null to null", () => slot[0] = null, 1, 0);

        if (module != 0)
        {
            RegisterFrozen register = Marshal.GetDelegateForFunctionPointer<RegisterFrozen>(
                NativeLibrary.GetExport(module, "GC_LxrPrototype_RegisterFrozenArray"));
            UnregisterFrozen unregister = Marshal.GetDelegateForFunctionPointer<UnregisterFrozen>(
                NativeLibrary.GetExport(module, "GC_LxrPrototype_UnregisterFrozen"));
            bool windows = OperatingSystem.IsWindows();
            nint memory = windows ? VirtualAlloc(0, 4096, 0x3000, 4) : Mmap(0, 4096, 3, 0x22, -1, 0);
            Check(memory != 0 && memory != -1, "Could not allocate the frozen-store fixture.");
            nint segment = 0;
            GCHandle observer = default;
            try
            {
                observer = RegisterFrozenTarget(register, memory, out segment);
                nint frozenAddress = memory + IntPtr.Size;
                slot[0] = old;
                Rearm();
                Measure("registered frozen value", () => slot[0] = Unsafe.As<nint, object>(ref frozenAddress), 1, 1);
                Check(slot[0] is object[] { Length: 1 }, "The registered frozen store was lost.");
                slot[0] = old;
            }
            finally
            {
                if (segment != 0)
                {
                    unregister(segment);
                    Check(collect(0) == 0, "Could not finish frozen-store fixture retirement.");
                }
                if (observer.IsAllocated)
                {
                    observer.Free();
                }
                Check(windows ? VirtualFree(memory, 0, 0x8000) : Munmap(memory, 4096) == 0,
                    "Could not release the frozen-store fixture.");
            }
        }

        foreach (int count in new[] { 11, 2201 })
        {
            BarrierMixed[] source = new BarrierMixed[count];
            BarrierMixed[] destination = new BarrierMixed[count];
            BarrierMixed value = new() { First = proposed, Number = long.MaxValue, Last = mismatch };
            source.AsSpan().Fill(value);
            destination.AsSpan().Fill(new BarrierMixed { First = old, Number = long.MinValue, Last = old });
            Rearm();
            Measure($"mixed copy {count}", () => source.AsSpan().CopyTo(destination),
                (ulong)(2 * count), (ulong)(2 * count),
                byteCount: (ulong)count * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true);
            for (int index = 0; index < count; index++)
            {
                Check(ReferenceEquals(source[index].First, value.First) &&
                    source[index].Number == value.Number &&
                    ReferenceEquals(source[index].Last, value.Last),
                    "Mixed copy changed its source.");
                Check(ReferenceEquals(destination[index].First, value.First) &&
                    destination[index].Number == value.Number &&
                    ReferenceEquals(destination[index].Last, value.Last),
                    "Mixed copy lost bytes or references.");
            }
            Action clearSpan = () => destination.AsSpan().Clear();
            clearSpan();
            for (int index = 0; index < count; index++)
            {
                destination[index].First = value.First;
                destination[index].Number = value.Number;
                destination[index].Last = value.Last;
            }
            Rearm();
            Measure($"mixed span clear {count}", clearSpan,
                (ulong)(2 * count), (ulong)(2 * count),
                byteCount: (ulong)count * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true, clear: true);
            CheckCleared(destination, "Mixed span clear");
            Array.Clear(destination);
            destination.AsSpan().Fill(value);
            Rearm();
            Measure($"mixed array clear {count}", () => Array.Clear(destination),
                (ulong)(2 * count), (ulong)(2 * count),
                byteCount: (ulong)count * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true, clear: true);
            CheckCleared(destination, "Mixed array clear");
            Array.Clear(destination, 1, count - 2);
            destination.AsSpan().Fill(value);
            Rearm();
            Measure($"partial array clear {count}", () => Array.Clear(destination, 1, count - 2),
                (ulong)(2 * (count - 2)), (ulong)(2 * (count - 2)),
                byteCount: (ulong)(count - 2) * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true, clear: true);
            for (int index = 0; index < count; index++)
            {
                BarrierMixed expected = index == 0 || index == count - 1 ? value : default;
                Check(ReferenceEquals(destination[index].First, expected.First) &&
                    destination[index].Number == expected.Number &&
                    ReferenceEquals(destination[index].Last, expected.Last),
                    "Partial array clear changed data outside its range or left a field uncleared.");
            }
            destination.AsSpan().Fill(value);
            Rearm();
            Measure($"typed fill {count}", () => destination.AsSpan().Fill(default),
                (ulong)(2 * count), (ulong)(2 * count));
            CheckCleared(destination, "Typed fill");

            source.AsSpan().Fill(new BarrierMixed { Number = 31 });
            destination.AsSpan().Fill(value);
            Rearm();
            Measure($"mixed null-reference copy {count}", () => source.AsSpan().CopyTo(destination),
                (ulong)(2 * count), (ulong)(2 * count),
                byteCount: (ulong)count * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true);
            for (int index = 0; index < count; index++)
            {
                Check(source[index].First is null && source[index].Number == 31 &&
                    source[index].Last is null, "Null-reference copy changed its source.");
                Check(destination[index].First is null && destination[index].Number == 31 &&
                    destination[index].Last is null, "Null-reference copy lost bytes or references.");
            }

            foreach (bool backward in new[] { false, true })
            {
                object[] originalFirst = new object[count];
                object[] originalLast = new object[count];
                for (int index = 0; index < count; index++)
                {
                    object first = new Node(2 * index);
                    object last = new Node(2 * index + 1);
                    source[index].First = first;
                    source[index].Number = index + 1;
                    source[index].Last = last;
                    originalFirst[index] = first;
                    originalLast[index] = last;
                }
                int from = backward ? 0 : 1;
                int to = backward ? 1 : 0;
                Rearm();
                Measure($"overlap {count} backward={backward}",
                    () => source.AsSpan(from, count - 1).CopyTo(source.AsSpan(to)),
                    (ulong)(2 * (count - 1)), (ulong)(2 * (count - 1)),
                    byteCount: (ulong)(count - 1) * (ulong)Unsafe.SizeOf<BarrierMixed>(), bulk: true);
                for (int index = 0; index < count; index++)
                {
                    int originalIndex = index >= to && index < to + count - 1 ? from + index - to : index;
                    Check(source[index].Number == originalIndex + 1 &&
                        ReferenceEquals(source[index].First, originalFirst[originalIndex]) &&
                        ReferenceEquals(source[index].Last, originalLast[originalIndex]),
                        "Overlapping copy changed data.");
                }
            }

            source.AsSpan().Fill(value);
            Rearm();
            ulong freshCollection = metric(5);
            BarrierMixed[] fresh = new BarrierMixed[count];
            Measure($"fresh copy {count}", () => source.AsSpan().CopyTo(fresh), 0, 0,
                byteCount: (ulong)count * (ulong)Unsafe.SizeOf<BarrierMixed>(), noUnloggedSlots: true);
            Check(metric(5) == freshCollection, "A collection made the fresh-copy destination old.");
            for (int index = 0; index < count; index++)
            {
                Check(ReferenceEquals(fresh[index].First, value.First) &&
                    fresh[index].Number == value.Number &&
                    ReferenceEquals(fresh[index].Last, value.Last),
                    "Fresh copy lost bytes or references.");
                Check(ReferenceEquals(source[index].First, value.First) &&
                    source[index].Number == value.Number &&
                    ReferenceEquals(source[index].Last, value.Last),
                    "Fresh copy changed its source.");
            }
            GC.KeepAlive(source);
            GC.KeepAlive(destination);
            GC.KeepAlive(fresh);
        }

        BarrierBox box = new()
        {
            Value = new BarrierLarge { First = old, Number = long.MaxValue, Last = proposed }
        };
        for (int index = 24; index < Unsafe.SizeOf<BarrierLarge>(); index++)
        {
            Unsafe.Add(ref Unsafe.As<BarrierLarge, byte>(ref box.Value), index) = 0xA5;
        }
        Rearm();
        Measure("large partial-object initobj", () => ClearBarrierLarge(ref box.Value),
            2, 2, byteCount: (ulong)Unsafe.SizeOf<BarrierLarge>(), bulk: true, clear: true);
        Check(box.Prefix == 17 && box.Suffix == 29, "Partial-object clear changed adjacent fields.");
        for (int index = 0; index < Unsafe.SizeOf<BarrierLarge>(); index++)
        {
            Check(Unsafe.Add(ref Unsafe.As<BarrierLarge, byte>(ref box.Value), index) == 0,
                "Large initobj left a nonzero byte.");
        }
        box.Value = new BarrierLarge { First = old, Number = 31, Last = proposed };
        if (counters)
        {
            SharedBulkClear clearBytes = (typeof(Buffer).GetMethod(
                "BulkClearWithWriteBarrier", BindingFlags.NonPublic | BindingFlags.Static) ??
                throw new InvalidOperationException("The runtime has no shared byte-count clear."))
                .CreateDelegate<SharedBulkClear>();
            byte scratch = 0;
            clearBytes(ref scratch, 0);
            for (int index = 24; index <= 50; index++)
            {
                Unsafe.Add(ref Unsafe.As<BarrierLarge, byte>(ref box.Value), index) = 0xA5;
            }
            Rearm();
            // Large-object promotion arms padding bits too. These bits require layout validation, not reference logging.
            Measure("unaligned non-reference byte range",
                () => clearBytes(ref Unsafe.Add(ref Unsafe.As<BarrierLarge, byte>(ref box.Value), 25), 25),
                0, 0, byteCount: 25, bulk: true, clear: true, destinationAlignment: 1);
            for (int index = 24; index <= 50; index++)
            {
                Check(Unsafe.Add(ref Unsafe.As<BarrierLarge, byte>(ref box.Value), index) ==
                    (index == 24 || index == 50 ? 0xA5 : 0),
                    "Byte-count clear lost a boundary byte or left an uncleared byte.");
            }
            Check(ReferenceEquals(box.Value.First, old) && ReferenceEquals(box.Value.Last, proposed) &&
                box.Value.Number == 31 && box.Prefix == 17 && box.Suffix == 29,
                "Byte-count clear changed a field outside its range.");

            BarrierClearRange[] ranges = new BarrierClearRange[1];
            foreach ((int start, ulong length) in new[]
            {
                (8, 0ul), (8, chunkBytes), (8, 2 * chunkBytes), (13, 2 * chunkBytes)
            })
            {
                ranges[0].Last = old;
                for (int index = 0; index < BarrierLargeBytes - IntPtr.Size; index++)
                {
                    Unsafe.Add(ref Unsafe.As<BarrierClearRange, byte>(ref ranges[0]), index) = 0xA5;
                }
                string name = $"byte clear offset={start} length={length}";
                Check((ulong)start + length < BarrierLargeBytes - (ulong)IntPtr.Size,
                    "The clear-control range has no non-reference end sentinel.");
                Rearm();
                Measure(name, () => clearBytes(
                    ref Unsafe.Add(ref Unsafe.As<BarrierClearRange, byte>(ref ranges[0]), start),
                    checked((nuint)length)), 0, 0, byteCount: length, bulk: true, clear: true,
                    destinationAlignment: (uint)(start % IntPtr.Size));
                for (int index = 0; index < BarrierLargeBytes - IntPtr.Size; index++)
                {
                    byte expected = index >= start && (ulong)(index - start) < length ? (byte)0 : (byte)0xA5;
                    Check(Unsafe.Add(ref Unsafe.As<BarrierClearRange, byte>(ref ranges[0]), index) == expected,
                        "A bounded clear changed an outside byte or left an inside byte nonzero.");
                }
                Check(ReferenceEquals(ranges[0].Last, old),
                    "A bounded clear changed the reference outside its range.");
            }
            GC.KeepAlive(ranges);
        }
        Rearm();
        Measure("interior reference clear",
            () => MemoryMarshal.CreateSpan(ref box.Value.Last, 1).Clear(), 1, 1,
            byteCount: (ulong)IntPtr.Size, bulk: true, clear: true);
        Check(ReferenceEquals(box.Value.First, old) && box.Value.Last is null && box.Value.Number == 31,
            "Interior clear changed a field outside its range.");
        GC.KeepAlive(box);
        GC.KeepAlive(slot);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static void ClearBarrierLarge(ref BarrierLarge value) => value = default;

    private static void VerifyRejectedSharedBarrierRange(Collect collect)
    {
        BarrierMixed value = new() { First = new Node(89), Number = 97, Last = new Node(101) };
        BarrierMixed[] source = [value, value];
        BarrierMixed[] destination = [value];
        Check(collect(1) == 0 && collect(1) == 0, "Invalid-range setup pauses failed.");
        Console.Error.WriteLine("CONTROL shared-barriers-invalid-range: the next copy must fail before writing.");
        // Run only in an isolated negative-control process: this deliberately crosses an old object's end.
        source.AsSpan().CopyTo(MemoryMarshal.CreateSpan(ref destination[0], 2));
        GC.KeepAlive(source);
        GC.KeepAlive(destination);
        throw new InvalidOperationException("The collector accepted a copy outside its destination object.");
    }

    private static void VerifySharedBarrierChunkMovement(
        nint module, GetMetric metric, Collect collect, bool clear)
    {
        Check(Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics") == "1",
            "The chunk-movement control requires shared-barrier metrics.");
        Check(metric(78) == 1, "The chunk-movement control requires nursery evacuation.");
        EnableStorage enable = Marshal.GetDelegateForFunctionPointer<EnableStorage>(
            NativeLibrary.GetExport(module, "GC_LxrPrototype_EnableStorageDiagnostics"));
        HandleAddress address = Marshal.GetDelegateForFunctionPointer<HandleAddress>(
            NativeLibrary.GetExport(module, "GC_LxrPrototype_GetHandleAddress"));
        Check(enable() == 0, "Could not enable chunk-movement diagnostics.");

        const int Count = 1000;
        BarrierMixed[] warmup = new BarrierMixed[Count];
        BarrierMixed[] warmupDestination = new BarrierMixed[Count];
        warmup.AsSpan().CopyTo(warmupDestination);
        warmupDestination.AsSpan().Clear();

        BarrierMixed[] source = new BarrierMixed[Count];
        BarrierMixed[] destination = new BarrierMixed[Count];
        object[] originalFirst = new object[Count];
        object[] originalLast = new object[Count];
        for (int index = 0; index < Count; index++)
        {
            object first = new Node(2 * index);
            object last = new Node(2 * index + 1);
            source[index].First = first;
            source[index].Number = index + 1;
            source[index].Last = last;
            originalFirst[index] = first;
            originalLast[index] = last;
            destination[index] = new BarrierMixed
            {
                First = new Node(-2 * index - 1),
                Number = -index - 1,
                Last = new Node(-2 * index - 2)
            };
        }
        GCHandle sourceHandle = GCHandle.Alloc(source);
        GCHandle destinationHandle = GCHandle.Alloc(destination);
        using ManualResetEventSlim ready = new();
        using ManualResetEventSlim start = new();
        uint callbackMetric = clear ? 465u : 464u;
        ulong callbackStart = 0;
        try
        {
            Task<int> pause = Task.Run(() =>
            {
                ready.Set();
                if (!start.Wait(TimeSpan.FromSeconds(30)))
                {
                    throw new TimeoutException("The chunk-movement writer did not start.");
                }
                long deadline = Environment.TickCount64 + 30000;
                while (metric(callbackMetric) == callbackStart)
                {
                    if (Environment.TickCount64 >= deadline)
                    {
                        throw new TimeoutException("The chunk-movement callback was not reached.");
                    }
                    Thread.Yield();
                }
                return collect(1);
            });
            Check(ready.Wait(TimeSpan.FromSeconds(30)), "The chunk-movement worker did not start.");
            nint sourceBefore = address(GCHandle.ToIntPtr(sourceHandle));
            nint destinationBefore = address(GCHandle.ToIntPtr(destinationHandle));
            Console.WriteLine($"shared_barrier_boundary kind={(clear ? "clear" : "copy")} " +
                $"source=0x{sourceBefore:x} destination=0x{destinationBefore:x} " +
                $"bytes={Count * Unsafe.SizeOf<BarrierMixed>()}");
            callbackStart = metric(callbackMetric);
            ulong collectionsBefore = metric(5);
            start.Set();
            if (clear)
            {
                destination.AsSpan().Clear();
            }
            else
            {
                source.AsSpan().CopyTo(destination);
            }
            ulong collectionsAfter = metric(5);
            Check(pause.Wait(TimeSpan.FromSeconds(30)), "The chunk-movement pause did not finish.");
            Check(pause.GetAwaiter().GetResult() == 0, "The chunk-movement pause failed.");
            Check(collectionsAfter > collectionsBefore, "No collection completed during the bulk call.");
            Check(address(GCHandle.ToIntPtr(sourceHandle)) != sourceBefore &&
                address(GCHandle.ToIntPtr(destinationHandle)) != destinationBefore,
                "The chunk-movement arrays did not move.");
            for (int index = 0; index < Count; index++)
            {
                Check(ReferenceEquals(source[index].First, originalFirst[index]) &&
                    source[index].Number == index + 1 &&
                    ReferenceEquals(source[index].Last, originalLast[index]),
                    "A moving bulk operation changed its source.");
                Check(ReferenceEquals(destination[index].First, clear ? null : originalFirst[index]) &&
                    destination[index].Number == (clear ? 0 : index + 1) &&
                    ReferenceEquals(destination[index].Last, clear ? null : originalLast[index]),
                    "A bulk operation used an old address after a collection.");
            }
            Console.WriteLine("PASS shared-barrier moved arrays and preserved bulk data; " +
                "the debugger trace must also prove a collection between callbacks.");
        }
        finally
        {
            sourceHandle.Free();
            destinationHandle.Free();
        }
    }
}
