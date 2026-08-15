// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

internal static class Program
{
    private const MethodImplOptions OptimizedNoInlining =
        MethodImplOptions.AggressiveOptimization | MethodImplOptions.NoInlining;

    private static int Main()
    {
        bool expectStandardAbi = Environment.GetEnvironmentVariable("P11_EXPECT_STANDARD_ABI") == "1";
        bool expectClobber = Environment.GetEnvironmentVariable("P11_EXPECT_CLOBBER") == "1";
        NativeHooks? nativeHooks = expectStandardAbi ? LoadNativeHooks() : null;
        GetCallCount? getCallCount = nativeHooks?.CallCount;
        ulong initialCallCount = getCallCount?.Invoke() ?? 0;

        ExerciseLiveState();
        ExerciseCollections();

        ulong finalCallCount = getCallCount?.Invoke() ?? 0;
        if (expectStandardAbi && (finalCallCount <= initialCallCount))
        {
            throw new InvalidOperationException("The standard-ABI write-barrier callback did not execute.");
        }

        uint clobberMask = nativeHooks?.ClobberMask() ?? 0;
        if (expectClobber && (clobberMask == 0))
        {
            throw new InvalidOperationException("The destructive write-barrier callback was not selected.");
        }

        List<string> executedState = ["integer", "object", "Vector128"];
        if (Vector256.IsHardwareAccelerated)
        {
            executedState.Add("Vector256");
        }
        if (Vector512.IsHardwareAccelerated)
        {
            executedState.Add("Vector512");
            if ((clobberMask & 4) != 0)
            {
                executedState.Add("opmask clobber");
            }
        }
        if ((clobberMask & 8) != 0)
        {
            executedState.Add("APX EGPR clobber");
        }

        Console.WriteLine(
            $"PASS: {string.Join(", ", executedState)}; callback delta {finalCallCount - initialCallCount}");
        return 0;
    }

    private static void ExerciseLiveState()
    {
        Node destination = new();
        Node value = new();
        Node[] array = new Node[2];
        Node live0 = new();
        Node live1 = new();
        Node live2 = new();
        Node live3 = new();

        for (int iteration = 0; iteration < 2_000; iteration++)
        {
            long seed = iteration + 101;
            ScalarState scalar = StoreScalars(
                destination,
                value,
                array,
                live0,
                live1,
                live2,
                live3,
                seed,
                seed + 1,
                seed + 2,
                seed + 3,
                seed + 4,
                seed + 5,
                seed + 6,
                seed + 7);

            if (!ReferenceEquals(scalar.Object0, live0) ||
                !ReferenceEquals(scalar.Object1, live1) ||
                !ReferenceEquals(scalar.Object2, live2) ||
                !ReferenceEquals(scalar.Object3, live3) ||
                (scalar.Integer0 != Mix(seed)) ||
                (scalar.Integer1 != Mix(seed + 1)) ||
                (scalar.Integer2 != Mix(seed + 2)) ||
                (scalar.Integer3 != Mix(seed + 3)) ||
                (scalar.Integer4 != Mix(seed + 4)) ||
                (scalar.Integer5 != Mix(seed + 5)) ||
                (scalar.Integer6 != Mix(seed + 6)) ||
                (scalar.Integer7 != Mix(seed + 7)))
            {
                throw new InvalidOperationException("Integer or object state was corrupted across a write barrier.");
            }

            Vector128<long> input128 = Vector128.Create(seed, seed + 1);
            Vector128State state128 = StoreVector128(destination, value, input128, seed);
            if (!state128.Value0.Equals(input128 + Vector128.Create(seed)) ||
                !state128.Value1.Equals(input128 - Vector128.Create(seed + 1)) ||
                !state128.Value2.Equals(input128 ^ Vector128.Create(seed + 2)) ||
                !state128.Value3.Equals(input128 | Vector128.Create(seed + 3)))
            {
                throw new InvalidOperationException("Vector128 state was corrupted across a write barrier.");
            }

            if (Vector256.IsHardwareAccelerated)
            {
                Vector256<long> input256 = Vector256.Create(seed, seed + 1, seed + 2, seed + 3);
                Vector256State state256 = StoreVector256(destination, value, input256, seed);
                if (!state256.Value0.Equals(input256 + Vector256.Create(seed)) ||
                    !state256.Value1.Equals(input256 - Vector256.Create(seed + 1)) ||
                    !state256.Value2.Equals(input256 ^ Vector256.Create(seed + 2)) ||
                    !state256.Value3.Equals(input256 | Vector256.Create(seed + 3)))
                {
                    throw new InvalidOperationException("Vector256 state was corrupted across a write barrier.");
                }
            }

            if (Vector512.IsHardwareAccelerated)
            {
                Vector512<long> input512 = Vector512.Create(
                    seed,
                    seed + 1,
                    seed + 2,
                    seed + 3,
                    seed + 4,
                    seed + 5,
                    seed + 6,
                    seed + 7);
                Vector512State state512 = StoreVector512(destination, value, input512, seed);
                if (!state512.Value0.Equals(input512 + Vector512.Create(seed)) ||
                    !state512.Value1.Equals(input512 - Vector512.Create(seed + 1)) ||
                    !state512.Value2.Equals(input512 ^ Vector512.Create(seed + 2)) ||
                    !state512.Value3.Equals(input512 | Vector512.Create(seed + 3)))
                {
                    throw new InvalidOperationException("Vector512 state was corrupted across a write barrier.");
                }
            }
        }
    }

    private static void ExerciseCollections()
    {
        Node root = new();
        for (int collection = 0; collection < 8; collection++)
        {
            Node current = root;
            for (int index = 0; index < 20_000; index++)
            {
                current.Next = new Node();
                current = current.Next;
            }

            GC.Collect();
            GC.WaitForPendingFinalizers();
            root.Next = null;
        }
    }

    [MethodImpl(OptimizedNoInlining)]
    private static ScalarState StoreScalars(
        Node destination,
        Node value,
        Node[] array,
        Node live0,
        Node live1,
        Node live2,
        Node live3,
        long integer0,
        long integer1,
        long integer2,
        long integer3,
        long integer4,
        long integer5,
        long integer6,
        long integer7)
    {
        long mixed0 = Mix(integer0);
        long mixed1 = Mix(integer1);
        long mixed2 = Mix(integer2);
        long mixed3 = Mix(integer3);
        long mixed4 = Mix(integer4);
        long mixed5 = Mix(integer5);
        long mixed6 = Mix(integer6);
        long mixed7 = Mix(integer7);
        destination.Next = value;
        array[mixed0 & 1] = live0;

        return new ScalarState(
            live0,
            live1,
            live2,
            live3,
            mixed0,
            mixed1,
            mixed2,
            mixed3,
            mixed4,
            mixed5,
            mixed6,
            mixed7);
    }

    [MethodImpl(OptimizedNoInlining)]
    private static Vector128State StoreVector128(
        Node destination,
        Node value,
        Vector128<long> input,
        long seed)
    {
        Vector128<long> value0 = input + Vector128.Create(seed);
        Vector128<long> value1 = input - Vector128.Create(seed + 1);
        Vector128<long> value2 = input ^ Vector128.Create(seed + 2);
        Vector128<long> value3 = input | Vector128.Create(seed + 3);
        destination.Next = value;

        return new Vector128State(value0, value1, value2, value3);
    }

    [MethodImpl(OptimizedNoInlining)]
    private static Vector256State StoreVector256(
        Node destination,
        Node value,
        Vector256<long> input,
        long seed)
    {
        Vector256<long> value0 = input + Vector256.Create(seed);
        Vector256<long> value1 = input - Vector256.Create(seed + 1);
        Vector256<long> value2 = input ^ Vector256.Create(seed + 2);
        Vector256<long> value3 = input | Vector256.Create(seed + 3);
        destination.Next = value;

        return new Vector256State(value0, value1, value2, value3);
    }

    [MethodImpl(OptimizedNoInlining)]
    private static Vector512State StoreVector512(
        Node destination,
        Node value,
        Vector512<long> input,
        long seed)
    {
        Vector512<long> value0 = input + Vector512.Create(seed);
        Vector512<long> value1 = input - Vector512.Create(seed + 1);
        Vector512<long> value2 = input ^ Vector512.Create(seed + 2);
        Vector512<long> value3 = input | Vector512.Create(seed + 3);
        destination.Next = value;

        return new Vector512State(value0, value1, value2, value3);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static long Mix(long value)
    {
        return (value * 1_664_525) + 1_013_904_223;
    }

    private static NativeHooks LoadNativeHooks()
    {
        string gcPath = Environment.GetEnvironmentVariable("DOTNET_GCPath")
            ?? throw new InvalidOperationException("DOTNET_GCPath is required.");
        nint library = NativeLibrary.Load(gcPath);
        nint callCount = NativeLibrary.GetExport(library, "GC_WriteBarrierTest_GetCallCount");
        nint clobberMask = NativeLibrary.GetExport(library, "GC_WriteBarrierTest_GetClobberMask");
        return new NativeHooks(
            Marshal.GetDelegateForFunctionPointer<GetCallCount>(callCount),
            Marshal.GetDelegateForFunctionPointer<GetClobberMask>(clobberMask));
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate ulong GetCallCount();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint GetClobberMask();

    private sealed record NativeHooks(GetCallCount CallCount, GetClobberMask ClobberMask);

    private readonly record struct ScalarState(
        Node Object0,
        Node Object1,
        Node Object2,
        Node Object3,
        long Integer0,
        long Integer1,
        long Integer2,
        long Integer3,
        long Integer4,
        long Integer5,
        long Integer6,
        long Integer7);

    private readonly record struct Vector128State(
        Vector128<long> Value0,
        Vector128<long> Value1,
        Vector128<long> Value2,
        Vector128<long> Value3);

    private readonly record struct Vector256State(
        Vector256<long> Value0,
        Vector256<long> Value1,
        Vector256<long> Value2,
        Vector256<long> Value3);

    private readonly record struct Vector512State(
        Vector512<long> Value0,
        Vector512<long> Value1,
        Vector512<long> Value2,
        Vector512<long> Value3);
}

internal sealed class Node
{
    public Node? Next;
}
