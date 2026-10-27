// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Buffers.Binary;
using System.IO;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Running;

if (args.Length == 1 && args[0] == "--verify")
{
    CollectorIdentity.Verify();
    return;
}
if (args.Length == 1 && (args[0] == "--diagnose" || args[0] == "--diagnose-legacy"))
{
    CollectorIdentity.Diagnostics = true;
    CollectorIdentity.LegacyDiagnostics = args[0] == "--diagnose-legacy";
    BarrierDiagnostics.Run();
    return;
}
BenchmarkSwitcher.FromAssembly(typeof(RepeatedScalarStores).Assembly).Run(args);

internal static class CollectorIdentity
{
    private delegate ulong GetMetric(uint metric);
    private delegate nint GetIdentity();
    private delegate int Collect(uint kind);
    private delegate int EnableStorage();
    private static GetMetric? s_metric;
    private static Collect? s_collect;
    private static nint s_module;
    private static bool s_diagnosticsEnabled;
    internal static bool Diagnostics { get; set; }
    internal static bool LegacyDiagnostics { get; set; }

    internal static void Verify()
    {
        string process = Environment.ProcessPath ??
            throw new InvalidOperationException("The benchmark process path is unavailable.");
        string directory = Path.GetDirectoryName(process) ??
            throw new InvalidOperationException("The benchmark runtime directory is unavailable.");
        string kind = Environment.GetEnvironmentVariable("BARRIER_COLLECTOR") ??
            throw new InvalidOperationException("Set BARRIER_COLLECTOR to LXR, Workstation or Server.");
        if (!Diagnostics && (s_diagnosticsEnabled ||
            Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics") != "0"))
        {
            throw new InvalidOperationException(
                "Timed/identity runs require DOTNET_LXRSharedBarrierMetrics=0 and disabled diagnostics.");
        }
        string manifest = Environment.GetEnvironmentVariable("BARRIER_FRAME_MANIFEST") ??
            throw new InvalidOperationException("Set BARRIER_FRAME_MANIFEST to the preserved frame identity file.");
        bool lxr = kind == "LXR";
        if (!lxr && kind != "Workstation" && kind != "Server")
        {
            throw new InvalidOperationException($"Unknown collector request: {kind}.");
        }
        string? name = Environment.GetEnvironmentVariable("DOTNET_GCName");
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DOTNET_GCPath")) ||
            !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("COMPlus_GCPath")) ||
            !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("COMPlus_GCName")))
        {
            throw new InvalidOperationException("Use per-frame DOTNET_GCName, not DOTNET_GCPath.");
        }
        if (lxr)
        {
            if (string.IsNullOrEmpty(name) || Path.GetFileName(name) != name)
            {
                throw new InvalidOperationException("LXR requires a collector file name in DOTNET_GCName.");
            }
        }
        else if (!string.IsNullOrEmpty(name) || GCSettings.IsServerGC != (kind == "Server"))
        {
            throw new InvalidOperationException($"Requested stock {kind}; custom name or actual GC mode differs.");
        }
        string path = Path.Combine(directory, lxr ? name! :
            OperatingSystem.IsWindows() ? "clrgc.dll" : "libclrgc.so");
        using JsonDocument expected = JsonDocument.Parse(File.ReadAllText(manifest));
        foreach (string file in new[]
        {
            process,
            path,
            typeof(object).Assembly.Location,
            Path.Combine(directory, OperatingSystem.IsWindows() ? "coreclr.dll" : "libcoreclr.so"),
            Path.Combine(directory, OperatingSystem.IsWindows() ? "clrjit.dll" : "libclrjit.so"),
        })
        {
            string? expectedHash = null;
            foreach (JsonElement entry in expected.RootElement.GetProperty("files").EnumerateArray())
            {
                string? entryName = entry.TryGetProperty("name", out JsonElement entryFile)
                    ? entryFile.GetString() : entry.GetProperty("file").GetString();
                if (string.Equals(entryName, Path.GetFileName(file),
                    StringComparison.OrdinalIgnoreCase))
                {
                    expectedHash = entry.TryGetProperty("sha256", out JsonElement hash)
                        ? hash.GetString() : entry.GetProperty("hash").GetString();
                    break;
                }
            }
            using FileStream stream = File.OpenRead(file);
            string actual = Convert.ToHexString(SHA256.HashData(stream));
            if (!string.Equals(actual, expectedHash, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException($"Frame hash differs or is missing: {file}; actual {actual}.");
            }
            Console.WriteLine($"BARRIER input={file} sha256={actual}");
        }
        if (lxr)
        {
            if (s_module == 0)
            {
                s_module = NativeLibrary.Load(path);
                s_metric = Marshal.GetDelegateForFunctionPointer<GetMetric>(
                    NativeLibrary.GetExport(s_module, "GC_LxrPrototype_GetMetric"));
                s_collect = Marshal.GetDelegateForFunctionPointer<Collect>(
                    NativeLibrary.GetExport(s_module, "GC_LxrPrototype_Collect"));
            }
            if (s_metric!(0) != 1)
            {
                throw new InvalidOperationException("The runtime did not initialize this LXR module.");
            }
            GetIdentity identity = Marshal.GetDelegateForFunctionPointer<GetIdentity>(
                NativeLibrary.GetExport(s_module, "GC_LxrPrototype_GetIdentity"));
            Console.WriteLine($"BARRIER collector={path} identity={Marshal.PtrToStringUTF8(identity())}");
            if (Diagnostics && !s_diagnosticsEnabled)
            {
                if ((s_metric(462) == ulong.MaxValue) != LegacyDiagnostics)
                {
                    throw new InvalidOperationException("Diagnostic mode does not match the frame counter interface.");
                }
                EnableStorage enable = Marshal.GetDelegateForFunctionPointer<EnableStorage>(
                    NativeLibrary.GetExport(s_module, "GC_LxrPrototype_EnableStorageDiagnostics"));
                if (enable() != 0)
                {
                    throw new InvalidOperationException("Could not enable separate barrier diagnostics.");
                }
                s_diagnosticsEnabled = true;
            }
        }
        Console.WriteLine($"BARRIER requested={kind} server={GCSettings.IsServerGC} runtime={process} " +
            $"diagnostics={Diagnostics} sharedMetrics={Environment.GetEnvironmentVariable("DOTNET_LXRSharedBarrierMetrics")}");
    }

    internal static void Rearm()
    {
        if (s_collect is not null)
        {
            if (s_collect(1) != 0 || s_collect(1) != 0)
                throw new InvalidOperationException("LXR benchmark epoch setup failed.");
        }
        else
        {
            GC.Collect();
            GC.Collect();
        }
    }

    internal static void Measure(string name, Action operation, ulong references, ulong callbacks, bool clear = false)
    {
        if (s_metric is null || !Diagnostics)
            throw new InvalidOperationException("Logging diagnostics require an LXR frame and --diagnose.");
        if (LegacyDiagnostics)
        {
            Console.WriteLine($"LEGACY diagnostic {name} expected_logs={references}; requires the external debugger result");
            ulong before = s_metric(5);
            s_metric(0x80000000u | checked((uint)references));
            operation();
            s_metric(0x90000000u | checked((uint)references));
            if (s_metric(5) != before)
                throw new InvalidOperationException("A collection invalidated the legacy diagnostic interval.");
            return;
        }
        ulong logs = s_metric(462);
        ulong old = s_metric(463);
        ulong moves = s_metric(464);
        ulong clears = s_metric(465);
        ulong collections = s_metric(5);
        operation();
        ulong logged = s_metric(462) - logs;
        ulong checkedOld = s_metric(463) - old;
        ulong moved = s_metric(464) - moves;
        ulong cleared = s_metric(465) - clears;
        if (logged != references || checkedOld != references ||
            moved != (clear ? 0 : callbacks) || cleared != (clear ? callbacks : 0) ||
            s_metric(5) != collections)
        {
            throw new InvalidOperationException(
                $"{name}: logged={logged}, old={checkedOld}, moves={moved}, clears={cleared}, expected={references}/{callbacks}.");
        }
        Console.WriteLine($"DIAGNOSTIC {name} logged={logged} old={checkedOld} moves={moved} clears={cleared}; not timed");
    }
}

public class RepeatedScalarStores
{
    private readonly object _value = new();
    private readonly object _comparand = new();
    private readonly object?[] _slots = new object?[1];

    [GlobalSetup]
    public void Setup()
    {
        CollectorIdentity.Verify();
        _slots[0] = _value;
        GC.Collect();
    }

    [Benchmark]
    public object? Assign()
    {
        _slots[0] = _value;
        return _slots[0];
    }

    [Benchmark]
    public object? AssignNull()
    {
        _slots[0] = null;
        return _slots[0];
    }

    [Benchmark]
    public object? AssignFrozen()
    {
        _slots[0] = "frozen";
        return _slots[0];
    }

    [Benchmark]
    public object? Exchange() => Interlocked.Exchange(ref _slots[0], _value);

    [Benchmark]
    public object? FailedCompareExchange() =>
        Interlocked.CompareExchange(ref _slots[0], _value, _comparand);
}

public class RepeatedBulkStores
{
    [StructLayout(LayoutKind.Explicit)]
    public struct Mixed
    {
        [FieldOffset(0)]
        public object? First;
        [FieldOffset(8)]
        public long Number;
        [FieldOffset(16)]
        public object? Last;
    }

    [Params(16, 2048, 8192)]
    public int Count { get; set; }

    private Mixed[] _source = null!;
    private Mixed[] _destination = null!;
    private readonly object _value = new();

    [GlobalSetup]
    public void Setup()
    {
        CollectorIdentity.Verify();
        _source = new Mixed[Count + 1];
        _destination = new Mixed[Count + 1];
        Restore();
        CollectorIdentity.Rearm();
    }

    public void Restore()
    {
        _source.AsSpan().Fill(new Mixed { First = _value, Number = 73, Last = _value });
        _destination.AsSpan().Fill(new Mixed { First = _value, Number = 29, Last = _value });
    }

    [Benchmark]
    public long Copy()
    {
        _source.AsSpan(0, Count).CopyTo(_destination);
        return _destination[Count - 1].Number;
    }

    [Benchmark]
    public long Overlap()
    {
        _source.AsSpan(0, Count).CopyTo(_source.AsSpan(1));
        return _source[Count].Number;
    }

    [Benchmark]
    public long Clear()
    {
        _destination.AsSpan(0, Count).Clear();
        return _destination[Count - 1].Number;
    }

    [Benchmark]
    public long Fill()
    {
        _destination.AsSpan(0, Count).Fill(new Mixed { First = _value, Number = 73, Last = _value });
        return _destination[Count - 1].Number;
    }
}

public class FirstWriteScalarStores
{
    public const int BatchSize = 4096;
    private readonly object _old = new();
    private readonly object _value = new();
    private readonly object _comparand = new();
    private readonly object?[] _slots = new object?[BatchSize];

    [GlobalSetup]
    public void Setup()
    {
        CollectorIdentity.Verify();
        PrepareIteration();
    }

    // First-write jobs must use one invocation and no unrolling.
    [IterationSetup]
    public void PrepareIteration()
    {
        _slots.AsSpan().Fill(_old);
        CollectorIdentity.Rearm();
    }

    [Benchmark(OperationsPerInvoke = BatchSize)]
    public object? Assign()
    {
        for (int index = 0; index < _slots.Length; index++) _slots[index] = _value;
        return _slots[^1];
    }

    [Benchmark(OperationsPerInvoke = BatchSize)]
    public object? AssignNull()
    {
        for (int index = 0; index < _slots.Length; index++) _slots[index] = null;
        return _slots[^1];
    }

    [Benchmark(OperationsPerInvoke = BatchSize)]
    public object? AssignFrozen()
    {
        for (int index = 0; index < _slots.Length; index++) _slots[index] = "frozen";
        return _slots[^1];
    }

    [Benchmark(OperationsPerInvoke = BatchSize)]
    public object? Exchange()
    {
        object? result = null;
        for (int index = 0; index < _slots.Length; index++)
            result = Interlocked.Exchange(ref _slots[index], _value);
        return result;
    }

    [Benchmark(OperationsPerInvoke = BatchSize)]
    public object? FailedCompareExchange()
    {
        object? result = null;
        for (int index = 0; index < _slots.Length; index++)
            result = Interlocked.CompareExchange(ref _slots[index], _value, _comparand);
        return result;
    }

    internal void CheckFailedCas()
    {
        foreach (object? item in _slots)
            if (!ReferenceEquals(item, _old)) throw new InvalidOperationException("Failed CAS changed storage.");
    }
}

public class FirstWriteBulkStores : RepeatedBulkStores
{
    [IterationSetup]
    public void PrepareIteration()
    {
        Restore();
        CollectorIdentity.Rearm();
    }
}

internal static class BarrierDiagnostics
{
    internal static void Run()
    {
        FirstWriteScalarStores scalar = new();
        scalar.Setup();
        foreach ((string name, Action operation) in new (string, Action)[]
        {
            ("assign", () => scalar.Assign()),
            ("null", () => scalar.AssignNull()),
            ("frozen", () => scalar.AssignFrozen()),
            ("exchange", () => scalar.Exchange()),
            ("failed CAS", () => scalar.FailedCompareExchange()),
        })
        {
            operation();
            scalar.PrepareIteration();
            CollectorIdentity.Measure($"first scalar {name}", operation, FirstWriteScalarStores.BatchSize, 0);
            if (name == "failed CAS") scalar.CheckFailedCas();
            CollectorIdentity.Measure($"repeated scalar {name}", operation, 0, 0);
            if (name == "failed CAS") scalar.CheckFailedCas();
        }
        ulong chunk = GetRuntimeChunk();
        foreach (int count in new[] { 16, 2048, 8192 })
        {
            FirstWriteBulkStores bulk = new() { Count = count };
            bulk.Setup();
            foreach ((string name, Action operation, bool clear) in new (string, Action, bool)[]
            {
                ("copy", () => bulk.Copy(), false),
                ("overlap", () => bulk.Overlap(), false),
                ("clear", () => bulk.Clear(), true),
                ("fill", () => bulk.Fill(), false),
            })
            {
                operation();
                bulk.PrepareIteration();
                ulong callbacks = name == "fill" ? 0 : 1 + ((ulong)count * 24 - 1) / chunk;
                CollectorIdentity.Measure($"first bulk {name} {count}", operation, (ulong)count * 2, callbacks, clear);
                CollectorIdentity.Measure($"repeated bulk {name} {count}", operation, 0, callbacks, clear);
            }
        }
    }

    private static uint GetRuntimeChunk()
    {
        byte[] il = (typeof(Buffer).GetMethod("BulkMoveWithWriteBarrier",
            BindingFlags.NonPublic | BindingFlags.Static) ??
            throw new InvalidOperationException("Missing shared bulk dispatch.")).GetMethodBody()?.GetILAsByteArray() ??
            throw new InvalidOperationException("Missing shared bulk dispatch IL.");
        int start = 0;
        while (start < il.Length && il[start] == OpCodes.Nop.Value) start++;
        if (il.Length - start < 8 || il[start] != OpCodes.Ldarg_2.Value ||
            il[start + 1] != OpCodes.Ldc_I4.Value ||
            (il[start + 6] != OpCodes.Conv_I.Value && il[start + 6] != OpCodes.Conv_U.Value) ||
            (il[start + 7] != OpCodes.Bgt_Un_S.Value && il[start + 7] != OpCodes.Bgt_Un.Value))
            throw new InvalidOperationException("Unknown shared bulk chunk IL shape.");
        uint chunk = BinaryPrimitives.ReadUInt32LittleEndian(il.AsSpan(start + 2, sizeof(uint)));
        if (chunk == 0 || chunk % IntPtr.Size != 0)
            throw new InvalidOperationException("Invalid shared bulk chunk.");
        return chunk;
    }
}
