// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Running;

namespace P14;

public static class Program
{
    public static void Main(string[] args) =>
        BenchmarkSwitcher.FromAssembly(typeof(VariableAllocationBenchmarks).Assembly).Run(args);
}

[MemoryDiagnoser]
public class VariableAllocationBenchmarks
{
    [Params(0, 16, 64, 256, 1024, 8192, 85000)]
    public int Length { get; set; }

    [Benchmark]
    public byte[] ByteArray() => new byte[Length];

    [Benchmark]
    public object[] ObjectArray() => new object[Length];

    [Benchmark]
    public string String() => new('x', Length);
}

[MemoryDiagnoser]
public class FixedAllocationBenchmarks
{
    private int _value;

    [Benchmark]
    public object Object() => new object();

    [Benchmark]
    public object Box() => _value++;

    [Benchmark]
    public FinalizableObject Finalizable() => new();

    public sealed class FinalizableObject
    {
        public static int Finalized;

        ~FinalizableObject()
        {
            Interlocked.Increment(ref Finalized);
        }
    }
}
