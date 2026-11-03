// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// P31: interior pointers that are held across collections. A managed byref, a Span<T>, a fixed pointer or a ref to a field is
// reported to the collector as an address inside an object, and the collector has to find the object. Each scenario keeps an
// object alive ONLY through such an address (the helpers return a ref and drop the object reference), runs collections while
// the address is live, and then reads the whole object back through the address and compares it with the expected content.
// If the collector did not find the object, or found the wrong one, the content differs or the process crashes.
//
// usage: InteriorStress [threads=8] [iterations=2000] [seed=1] [collectEveryMs=3]
//   DOTNET_GCPath selects the collector (the default variant or the walk variant of LAXORI).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

[StructLayout(LayoutKind.Sequential)]
sealed class Blob
{
    public long F00, F01, F02, F03, F04, F05, F06, F07, F08, F09, F10, F11, F12, F13, F14, F15;
    public long F16, F17, F18, F19, F20, F21, F22, F23, F24, F25, F26, F27, F28, F29, F30, F31;
}

[StructLayout(LayoutKind.Sequential)]
struct Quad
{
    public long A, B, C, D;
}

sealed class Payload
{
    public int Id;
    public Payload? Next;
}

static unsafe class InteriorStress
{
    static long s_ok;
    static long s_failures;
    static readonly int[] ByteSizes =
    {
        1, 8, 16, 24, 31, 32, 100, 200, 232, 240, 248, 256, 264, 488, 504, 512, 520, 768, 1000, 4000, 8000, 16000, 32000,
    };

    static void Fail(string message)
    {
        Interlocked.Increment(ref s_failures);
        Console.Error.WriteLine("FAIL: " + message);
    }

    // --- helpers that return an interior address and drop the object ---------------------------------------------------

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref int MakeIntRef(int length, int seed, out int index)
    {
        int[] array = new int[length];
        for (int i = 0; i < length; i++)
        {
            array[i] = i * 31 + seed;
        }
        index = length / 2;
        return ref array[index];
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyIntRef(ref int middle, int index, int length, int seed)
    {
        for (int i = 0; i < length; i++)
        {
            if (Unsafe.Add(ref middle, i - index) != i * 31 + seed)
            {
                return false;
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref byte MakeByteRef(int length, byte seed, out int index, bool pinned)
    {
        byte[] array = pinned ? GC.AllocateArray<byte>(length, pinned: true) : new byte[length];
        for (int i = 0; i < length; i++)
        {
            array[i] = (byte)(i * 7 + seed);
        }
        index = (length * 3) / 5;
        return ref array[index];
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyByteRef(ref byte middle, int index, int length, byte seed)
    {
        for (int i = 0; i < length; i++)
        {
            if (Unsafe.Add(ref middle, i - index) != (byte)(i * 7 + seed))
            {
                return false;
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref long MakeBlobRef(long seed)
    {
        Blob blob = new Blob();
        ref long first = ref blob.F00;
        for (int i = 0; i < 32; i++)
        {
            Unsafe.Add(ref first, i) = seed + i;
        }
        return ref blob.F16;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyBlobRef(ref long f16, long seed)
    {
        for (int i = 0; i < 32; i++)
        {
            if (Unsafe.Add(ref f16, i - 16) != seed + i)
            {
                return false;
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref Quad MakeQuadRef(int count, long seed, out int index)
    {
        Quad[] array = new Quad[count];
        for (int i = 0; i < count; i++)
        {
            array[i] = new Quad { A = seed + i, B = seed * 2 + i, C = seed * 3 + i, D = seed * 5 + i };
        }
        index = count - 2;
        return ref array[index];
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyQuadRef(ref Quad at, int index, int count, long seed)
    {
        for (int i = 0; i < count; i++)
        {
            ref Quad q = ref Unsafe.Add(ref at, i - index);
            if (q.A != seed + i || q.B != seed * 2 + i || q.C != seed * 3 + i || q.D != seed * 5 + i)
            {
                return false;
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref object? MakeObjectRef(int length, int seed, out int index)
    {
        object?[] array = new object?[length];
        for (int i = 0; i < length; i++)
        {
            array[i] = new Payload { Id = seed + i };
        }
        index = length / 3;
        return ref array[index];
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyObjectRef(ref object? at, int index, int length, int seed)
    {
        for (int i = 0; i < length; i++)
        {
            object? value = Unsafe.Add(ref at, i - index);
            if (value is not Payload p || p.Id != seed + i)
            {
                return false;
            }
        }
        return true;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref char MakeCharRef(int length, char seed, out int index)
    {
        char[] chars = new char[length];
        for (int i = 0; i < length; i++)
        {
            chars[i] = (char)(seed + (i % 20));
        }
        string text = new string(chars);
        index = length / 2;
        return ref Unsafe.Add(ref MemoryMarshal.GetReference(text.AsSpan()), index);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static bool VerifyCharRef(ref char at, int index, int length, char seed)
    {
        for (int i = 0; i < length; i++)
        {
            if (Unsafe.Add(ref at, i - index) != (char)(seed + (i % 20)))
            {
                return false;
            }
        }
        return true;
    }

    // --- scenarios --------------------------------------------------------------------------------------------------

    static void Collect(Random rng)
    {
        switch (rng.Next(4))
        {
            case 0: GC.Collect(); break;
            case 1: GC.Collect(0); break;
            case 2: GC.Collect(2, GCCollectionMode.Forced, blocking: true); break;
            default: Churn(rng, 200 + rng.Next(800)); break;
        }
    }

    // Garbage that fills young blocks and leaves holes after the survivors die.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void Churn(Random rng, int count)
    {
        var keep = new List<object>();
        for (int i = 0; i < count; i++)
        {
            object o = rng.Next(4) switch
            {
                0 => new byte[rng.Next(1, 300)],
                1 => new Payload { Id = i },
                2 => new long[rng.Next(1, 64)],
                _ => new string('x', rng.Next(1, 100)),
            };
            if ((i & 7) == 0)
            {
                keep.Add(o);
            }
        }
        GC.KeepAlive(keep);
    }

    static void IntArrayAcrossGc(Random rng, int seed)
    {
        int length = 1 + rng.Next(rng.Next(8) == 0 ? 20000 : 400);
        ref int middle = ref MakeIntRef(length, seed, out int index);
        Collect(rng);
        bool ok = VerifyIntRef(ref middle, index, length, seed);
        Collect(rng);
        ok &= VerifyIntRef(ref middle, index, length, seed);
        Report(ok, "int[] through a byref across collections, length " + length);
    }

    static void ByteArrayAcrossGc(Random rng, byte seed, bool pinned)
    {
        int length = ByteSizes[rng.Next(ByteSizes.Length)];
        ref byte middle = ref MakeByteRef(length, seed, out int index, pinned);
        Collect(rng);
        bool ok = VerifyByteRef(ref middle, index, length, seed);
        Collect(rng);
        ok &= VerifyByteRef(ref middle, index, length, seed);
        Report(ok, (pinned ? "pinned-heap " : "") + "byte[] through a byref, length " + length);
    }

    static void BlobFieldAcrossGc(Random rng, long seed)
    {
        ref long f16 = ref MakeBlobRef(seed);
        Collect(rng);
        bool ok = VerifyBlobRef(ref f16, seed);
        // Promote it, then check it again as a mature object.
        GC.Collect();
        GC.Collect();
        ok &= VerifyBlobRef(ref f16, seed);
        Report(ok, "class field byref across collections");
    }

    static void StructArrayAcrossGc(Random rng, long seed)
    {
        int count = 3 + rng.Next(rng.Next(6) == 0 ? 3000 : 40);
        ref Quad at = ref MakeQuadRef(count, seed, out int index);
        Collect(rng);
        bool ok = VerifyQuadRef(ref at, index, count, seed);
        Collect(rng);
        ok &= VerifyQuadRef(ref at, index, count, seed);
        Report(ok, "struct array through a byref, count " + count);
    }

    static void ReferenceArrayAcrossGc(Random rng, int seed)
    {
        int length = 3 + rng.Next(300);
        ref object? at = ref MakeObjectRef(length, seed, out int index);
        Collect(rng);
        bool ok = VerifyObjectRef(ref at, index, length, seed);
        // A store through the byref goes through the write barrier. The new object must be reachable after a collection.
        Payload fresh = new Payload { Id = seed + index };
        at = fresh;
        Collect(rng);
        GC.Collect();
        ok &= VerifyObjectRef(ref at, index, length, seed);
        Report(ok, "object[] through a byref, with a store through it, length " + length);
    }

    static void StringCharAcrossGc(Random rng, char seed)
    {
        int length = 2 + rng.Next(rng.Next(6) == 0 ? 5000 : 200);
        ref char at = ref MakeCharRef(length, seed, out int index);
        Collect(rng);
        bool ok = VerifyCharRef(ref at, index, length, seed);
        Report(ok, "string through a byref, length " + length);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void FixedAcrossGc(Random rng, byte seed)
    {
        byte[] array = new byte[ByteSizes[rng.Next(ByteSizes.Length)] + 16];
        for (int i = 0; i < array.Length; i++)
        {
            array[i] = (byte)(i * 7 + seed);
        }
        int index = array.Length / 2;
        int length = array.Length;
        fixed (byte* p = &array[index])
        {
            byte* before = p;
            array = null!;
            Collect(rng);
            Collect(rng);
            bool ok = p == before;
            for (int i = 0; i < length && ok; i++)
            {
                ok = p[i - index] == (byte)(i * 7 + seed);
            }
            Report(ok, "fixed pointer into the middle of byte[], length " + length);
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void PinnedHandleAcrossGc(Random rng, byte seed)
    {
        byte[] array = new byte[ByteSizes[rng.Next(ByteSizes.Length)] + 8];
        for (int i = 0; i < array.Length; i++)
        {
            array[i] = (byte)(i * 7 + seed);
        }
        GCHandle handle = GCHandle.Alloc(array, GCHandleType.Pinned);
        byte* p = (byte*)handle.AddrOfPinnedObject();
        int length = array.Length;
        array = null!;
        Collect(rng);
        GC.Collect();
        byte[] again = (byte[])handle.Target!;
        bool ok = again.Length == length &&
            (byte*)Unsafe.AsPointer(ref MemoryMarshal.GetArrayDataReference(again)) == p;
        for (int i = 0; i < length && ok; i++)
        {
            ok = p[i] == (byte)(i * 7 + seed);
        }
        handle.Free();
        Report(ok, "pinned handle address is stable and the content is intact");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void SpanAcrossGc(Random rng, int seed)
    {
        int[] array = new int[64 + rng.Next(5000)];
        for (int i = 0; i < array.Length; i++)
        {
            array[i] = i + seed;
        }
        int start = array.Length / 3;
        int count = array.Length / 2;
        Span<int> span = array.AsSpan(start, count);
        array = null!;
        Collect(rng);
        bool ok = true;
        for (int i = 0; i < span.Length; i++)
        {
            ok &= span[i] == start + i + seed;
        }
        span[0] = -1;
        Collect(rng);
        ok &= span[0] == -1;
        Report(ok, "Span<int> over the middle of an array, count " + count);
    }

    // A byref into an old object and a byref into a young object, both in reused holes next to dead objects.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void HolesNextToDeadObjects(Random rng, int seed)
    {
        const int Count = 600;
        var all = new List<int[]>(Count);
        for (int i = 0; i < Count; i++)
        {
            int[] array = new int[1 + rng.Next(80)];
            array[array.Length / 2] = seed + i;
            all.Add(array);
        }
        GC.Collect();
        GC.Collect();
        // Half of them die. The survivors stay where they are, and the holes between them are reused by the next allocations.
        var survivors = new List<int[]>();
        for (int i = 0; i < Count; i++)
        {
            if ((i & 1) == 0 || (i % 7) == 0)
            {
                survivors.Add(all[i]);
            }
        }
        all = null!;
        GC.Collect();
        var fresh = new List<int[]>();
        for (int i = 0; i < Count; i++)
        {
            int[] array = new int[1 + rng.Next(80)];
            array[array.Length / 2] = -seed - i;
            fresh.Add(array);
        }
        int[] oldArray = survivors[survivors.Count / 2];
        ref int oldRef = ref oldArray[oldArray.Length / 2];
        int oldValue = oldRef;
        int[] newArray = fresh[fresh.Count / 2];
        ref int newRef = ref newArray[newArray.Length / 2];
        int newValue = newRef;
        oldArray = null!;
        newArray = null!;
        survivors = null!;
        fresh = null!;
        Collect(rng);
        GC.Collect();
        Report(oldRef == oldValue && newRef == newValue, "interior refs into old and young objects in reused holes");
    }

    // Bulk copies of references into old arrays: the destination of the bulk write barrier is an address inside the array.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void BulkCopyIntoOldArray(Random rng, int seed)
    {
        object?[] destination = new object?[500];
        for (int i = 0; i < destination.Length; i++)
        {
            destination[i] = new Payload { Id = seed + i };
        }
        GC.Collect();
        GC.Collect();
        object?[] source = new object?[200];
        for (int i = 0; i < source.Length; i++)
        {
            source[i] = new Payload { Id = 100000 + seed + i };
        }
        int at = 37 + rng.Next(200);
        Array.Copy(source, 0, destination, at, source.Length);
        source = null!;
        Collect(rng);
        GC.Collect();
        bool ok = true;
        for (int i = 0; i < 200 && ok; i++)
        {
            ok = destination[at + i] is Payload p && p.Id == 100000 + seed + i;
        }
        Report(ok, "Array.Copy of references into an old array");
    }

    static void Report(bool ok, string what)
    {
        if (ok)
        {
            Interlocked.Increment(ref s_ok);
        }
        else
        {
            Fail(what);
        }
    }

    static void Worker(object? state)
    {
        var (index, iterations, seed) = ((int, int, int))state!;
        var rng = new Random(seed * 7919 + index);
        for (int i = 0; i < iterations; i++)
        {
            int s = rng.Next();
            switch (rng.Next(14))
            {
                case 0: IntArrayAcrossGc(rng, s); break;
                case 1: ByteArrayAcrossGc(rng, (byte)s, false); break;
                case 2: ByteArrayAcrossGc(rng, (byte)s, true); break;
                case 3: BlobFieldAcrossGc(rng, s); break;
                case 4: StructArrayAcrossGc(rng, s); break;
                case 5: ReferenceArrayAcrossGc(rng, s); break;
                case 6: StringCharAcrossGc(rng, (char)('A' + (s & 15))); break;
                case 7: FixedAcrossGc(rng, (byte)s); break;
                case 8: PinnedHandleAcrossGc(rng, (byte)s); break;
                case 9: SpanAcrossGc(rng, s); break;
                case 10: HolesNextToDeadObjects(rng, s); break;
                case 11: BulkCopyIntoOldArray(rng, s); break;
                case 12: IntArrayAcrossGc(rng, s); break;
                default: Churn(rng, 100 + rng.Next(2000)); break;
            }
        }
    }

    static int Main(string[] args)
    {
        int threads = args.Length > 0 ? int.Parse(args[0]) : 8;
        int iterations = args.Length > 1 ? int.Parse(args[1]) : 2000;
        int seed = args.Length > 2 ? int.Parse(args[2]) : 1;
        int collectEvery = args.Length > 3 ? int.Parse(args[3]) : 3;
        var stopwatch = Stopwatch.StartNew();
        bool done = false;
        var collector = new Thread(() =>
        {
            var rng = new Random(seed);
            while (!Volatile.Read(ref done))
            {
                Thread.Sleep(collectEvery);
                if (rng.Next(3) == 0)
                {
                    GC.Collect();
                }
            }
        });
        collector.Start();
        var pool = new Thread[threads];
        for (int i = 0; i < threads; i++)
        {
            pool[i] = new Thread(Worker, 16 * 1024 * 1024);
            pool[i].Start((i, iterations, seed));
        }
        foreach (Thread thread in pool)
        {
            thread.Join();
        }
        Volatile.Write(ref done, true);
        collector.Join();
        long failures = Interlocked.Read(ref s_failures);
        Console.WriteLine($"InteriorStress {(failures == 0 ? "PASS" : "FAIL")} threads={threads} iterations={iterations} " +
            $"seed={seed} ok={Interlocked.Read(ref s_ok)} failures={failures} gcs={GC.CollectionCount(0)}/{GC.CollectionCount(2)} " +
            $"ms={stopwatch.ElapsedMilliseconds}");
        return failures == 0 ? 0 : 1;
    }
}
