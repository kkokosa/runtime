// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Runtime.CompilerServices;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Columns;
using BenchmarkDotNet.Running;

namespace P11.WriteBarrierBenchmarks;

public static class Program
{
    public static void Main(string[] args)
    {
        if (args is ["--direct"])
        {
            var benchmark = new WriteBarrierBenchmark();
            benchmark.Setup();
            object fieldValue = benchmark.FieldStores();
            object arrayValue = benchmark.ArrayStores();
            object copyValue = benchmark.ReferenceArrayCopy();
            int clearLength = benchmark.ReferenceArrayClear();
            Console.WriteLine(
                ReferenceEquals(fieldValue, arrayValue) &&
                ReferenceEquals(arrayValue, copyValue) &&
                (clearLength == 16)
                    ? "PASS"
                    : "FAIL");
            return;
        }

        BenchmarkSwitcher.FromAssembly(typeof(WriteBarrierBenchmark).Assembly).Run(args);
    }
}

[MinColumn]
[MaxColumn]
[Q1Column]
[Q3Column]
public class WriteBarrierBenchmark
{
    private readonly Fields _fields = new();
    private readonly object[] _array = new object[16];
    private readonly object[] _copySource = new object[16];
    private readonly object[] _copyDestination = new object[16];
    private object _value = null!;

    [GlobalSetup]
    public void Setup()
    {
        _value = new object();
        Array.Fill(_copySource, _value);
        Array.Fill(_copyDestination, _value);
    }

    [Benchmark(OperationsPerInvoke = 16)]
    [MethodImpl(MethodImplOptions.NoInlining)]
    public object FieldStores()
    {
        _fields.F00 = _value;
        _fields.F01 = _value;
        _fields.F02 = _value;
        _fields.F03 = _value;
        _fields.F04 = _value;
        _fields.F05 = _value;
        _fields.F06 = _value;
        _fields.F07 = _value;
        _fields.F08 = _value;
        _fields.F09 = _value;
        _fields.F10 = _value;
        _fields.F11 = _value;
        _fields.F12 = _value;
        _fields.F13 = _value;
        _fields.F14 = _value;
        _fields.F15 = _value;

        return _fields.F15;
    }

    [Benchmark(OperationsPerInvoke = 16)]
    [MethodImpl(MethodImplOptions.NoInlining)]
    public object ArrayStores()
    {
        _array[0] = _value;
        _array[1] = _value;
        _array[2] = _value;
        _array[3] = _value;
        _array[4] = _value;
        _array[5] = _value;
        _array[6] = _value;
        _array[7] = _value;
        _array[8] = _value;
        _array[9] = _value;
        _array[10] = _value;
        _array[11] = _value;
        _array[12] = _value;
        _array[13] = _value;
        _array[14] = _value;
        _array[15] = _value;

        return _array[15];
    }

    [Benchmark(OperationsPerInvoke = 16)]
    [MethodImpl(MethodImplOptions.NoInlining)]
    public object ReferenceArrayCopy()
    {
        Array.Copy(_copySource, _copyDestination, _copySource.Length);
        return _copyDestination[^1];
    }

    [Benchmark(OperationsPerInvoke = 16)]
    [MethodImpl(MethodImplOptions.NoInlining)]
    public int ReferenceArrayClear()
    {
        Array.Clear(_copyDestination);
        return _copyDestination.Length;
    }

    private sealed class Fields
    {
        public object F00 = null!;
        public object F01 = null!;
        public object F02 = null!;
        public object F03 = null!;
        public object F04 = null!;
        public object F05 = null!;
        public object F06 = null!;
        public object F07 = null!;
        public object F08 = null!;
        public object F09 = null!;
        public object F10 = null!;
        public object F11 = null!;
        public object F12 = null!;
        public object F13 = null!;
        public object F14 = null!;
        public object F15 = null!;
    }
}
