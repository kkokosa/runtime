// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// P49 scaling driver. Modes (the first argument after the output directory):
//   bigheap <liveMB> <seconds>              item 8a: a large live heap of small linked objects with churn (writes, dying ranges)
//   threads <T> <depth> <allocThreads> <seconds> [minPauses]
//                                           item 8c: T parked threads, each in a recursion of <depth> frames; allocThreads threads allocate
//   alloc <T> <depth> <seconds> [minPauses] item 8c: T threads, all allocating (like a server), each at <depth> frames
//   handles <kind> <N> <seconds> [churn]    item 11a: N weak handles; kind = weak, long, wr, wrt, cwt, dep, strong
//   frozen <N> <seconds>                    item 11b: N string literals (frozen objects), a large frozen heap
// Output files in the output directory: result.json, pauses.csv (event listener), lxr-pauses.csv (LXR per-pause phase records).
// The LXR per-pause records need the library built with -DCLR_CMAKE_LXR_P49_EXP=ON and LXR_P49_TRACE=1.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;

internal sealed class Obj
{
    public Obj? Next;
    public object? Data;
    public long A;
    public long B;
    public Obj(Obj? next) { Next = next; }
}

internal static class ScalingDriver
{
    private sealed class PauseListener : System.Diagnostics.Tracing.EventListener
    {
        public readonly List<(int Id, DateTime Time)> Events = new();

        protected override void OnEventSourceCreated(System.Diagnostics.Tracing.EventSource source)
        {
            if (source.Name == "Microsoft-Windows-DotNETRuntime")
                EnableEvents(source, System.Diagnostics.Tracing.EventLevel.Informational, (System.Diagnostics.Tracing.EventKeywords)0x1);
        }

        protected override void OnEventWritten(System.Diagnostics.Tracing.EventWrittenEventArgs e)
        {
            if (e.EventId == 9 || e.EventId == 3)
                lock (Events) Events.Add((e.EventId, e.TimeStamp));
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate ulong Metric(uint id);

    [DllImport("libc")]
    private static extern int clock_gettime(int clock, out Timespec value);

    private struct Timespec { public long Seconds; public long Nanoseconds; }

    private static long Now()
    {
        if (clock_gettime(1, out Timespec value) != 0) throw new InvalidOperationException("clock_gettime failed.");
        return checked(value.Seconds * 1_000_000_000 + value.Nanoseconds);
    }

    private static long StatusKb(string key)
    {
        foreach (string line in File.ReadLines("/proc/self/status"))
            if (line.StartsWith(key, StringComparison.Ordinal))
                return long.Parse(new string(Array.FindAll(line.ToCharArray(), char.IsDigit)), CultureInfo.InvariantCulture);
        return -1;
    }

    private static volatile bool s_stop;
    private static long s_checksum;

    [ThreadStatic] private static ulong t_state;

    private static ulong Next()
    {
        ulong x = t_state;
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
        t_state = x;
        return x * 0x2545F4914F6CDD1DUL;
    }

    private static int Rnd(int n) => (int)((Next() >> 33) % (ulong)n);

    // The allocation work of one thread: chains of small objects, a small ring keeps a few of them alive for a while.
    // The hook (if any) runs once for every 256 operations.
    private static long AllocLoop(int seed, Action? hook)
    {
        t_state = 0x9E3779B97F4A7C15UL ^ ((ulong)seed * 0xD1B54A32D192ED03UL) | 1;
        Obj?[] ring = new Obj?[256];
        long sum = 0;
        long i = 0;
        while (!s_stop)
        {
            Obj? head = null;
            for (int k = 0; k < 6; k++) { head = new Obj(head) { A = k + i }; }
            head!.Data = new byte[64];
            ring[i & 255] = head;
            sum += head.A + (ring[(i * 7) & 255]?.A ?? 0);
            i++;
            if ((i & 255) == 0) hook?.Invoke();
        }
        return sum;
    }

    // ---------------------------------------------------------------- 8a
    private sealed class Node
    {
        public Node? Next;
        public byte[] Payload;
        public long A;
        public long B;
        public Node(Node? next, long a) { Next = next; Payload = new byte[32]; A = a; B = a * 3; }
    }

    private const int ChunkSlots = 1024;
    private const int NodeBytes = 104; // 48 (node) + 56 (32-byte array)

    private static Node[][]? s_table;

    private static void BuildBigHeap(long liveMB)
    {
        long entries = liveMB * 1_000_000L / NodeBytes;
        int chunks = (int)((entries + ChunkSlots - 1) / ChunkSlots);
        Node[][] table = new Node[chunks][];
        s_table = table;
        long sequence = 0;
        for (int c = 0; c < chunks; c++)
        {
            Node[] chunk = new Node[ChunkSlots];
            Node? previous = null;
            for (int s = 0; s < ChunkSlots; s++)
            {
                Node node = new Node(previous, sequence++);
                chunk[s] = node;
                previous = node;
            }
            table[c] = chunk;
        }
    }

    // One churn loop: 70% short-lived garbage, 25% replace one entry, 5% replace a run of 256 neighbours (they were allocated
    // together, so they die together and leave dead lines and blocks in the old space).
    private static long BigHeapLoop(int rangePerMille, int singlePerMille, int spin)
    {
        t_state = 0x1234567887654321UL;
        Node[][] table = s_table!;
        long sum = 0;
        long i = 0;
        while (!s_stop)
        {
            for (int w = 0; w < spin; w++) sum += w ^ i;
            int r = Rnd(1000);
            if (r < 1000 - rangePerMille - singlePerMille)
            {
                Obj? head = null;
                for (int k = 0; k < 3; k++) { head = new Obj(head) { A = k }; }
                head!.Data = new byte[48];
                sum += head.A;
            }
            else if (r < 1000 - rangePerMille)
            {
                Node[] chunk = table[Rnd(table.Length)];
                int s = Rnd(ChunkSlots);
                Node node = new Node(chunk[(s + 1) & (ChunkSlots - 1)], i);
                chunk[s] = node;
                sum += node.A;
            }
            else
            {
                Node[] chunk = table[Rnd(table.Length)];
                int s0 = Rnd(ChunkSlots - 256);
                Node? previous = null;
                for (int s = s0; s < s0 + 256; s++)
                {
                    Node node = new Node(previous, i + s);
                    chunk[s] = node;
                    previous = node;
                }
                sum += previous!.A;
            }
            i++;
        }
        return sum;
    }

    // ---------------------------------------------------------------- 8c
    [MethodImpl(MethodImplOptions.NoInlining)]
    private static long Park(int depth, Obj? parent, ManualResetEventSlim gate, ref int ready)
    {
        Obj a = new Obj(parent) { A = depth };
        Obj b = new Obj(a) { A = depth + 1 };
        Obj c = new Obj(b) { A = depth + 2 };
        Obj d = new Obj(c) { A = depth + 3 };
        long r;
        if (depth > 0)
        {
            r = Park(depth - 1, d, gate, ref ready);
        }
        else
        {
            Interlocked.Increment(ref ready);
            gate.Wait();
            r = 0;
        }
        return r + a.A + b.A + c.A + d.A;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static long DeepAlloc(int depth, Obj? parent, int seed)
    {
        Obj a = new Obj(parent) { A = depth };
        Obj b = new Obj(a) { A = depth + 1 };
        Obj c = new Obj(b) { A = depth + 2 };
        Obj d = new Obj(c) { A = depth + 3 };
        long r = depth > 0 ? DeepAlloc(depth - 1, d, seed) : AllocLoop(seed, null);
        return r + a.A + b.A + c.A + d.A;
    }

    // ---------------------------------------------------------------- 11a
    private static Action? SetupHandles(string kind, int n)
    {
        if (n == 0 || kind == "none") return null;
        object[] targets = new object[n];
        for (int i = 0; i < n; i++) targets[i] = new Obj(null) { A = i };
        object keep = targets;
        t_state = 0xABCDEF0123456789UL;
        switch (kind)
        {
            case "plain":
            {
                // Control: the same target array and replacement churn, but no handle at all.
                s_keep = keep;
                return () =>
                {
                    int i = Rnd(n);
                    targets[i] = new Obj(null) { A = i };
                };
            }
            case "weak":
            case "long":
            {
                GCHandleType type = kind == "weak" ? GCHandleType.Weak : GCHandleType.WeakTrackResurrection;
                GCHandle[] handles = new GCHandle[n];
                for (int i = 0; i < n; i++) handles[i] = GCHandle.Alloc(targets[i], type);
                s_keep = new object[] { keep, handles };
                return () =>
                {
                    int i = Rnd(n);
                    handles[i].Free();
                    object o = new Obj(null) { A = i };
                    targets[i] = o;
                    handles[i] = GCHandle.Alloc(o, type);
                };
            }
            case "strong":
            {
                GCHandle[] handles = new GCHandle[n];
                for (int i = 0; i < n; i++) handles[i] = GCHandle.Alloc(targets[i], GCHandleType.Normal);
                s_keep = new object[] { keep, handles };
                return () =>
                {
                    int i = Rnd(n);
                    handles[i].Free();
                    object o = new Obj(null) { A = i };
                    targets[i] = o;
                    handles[i] = GCHandle.Alloc(o, GCHandleType.Normal);
                };
            }
            case "wr":
            {
                WeakReference[] refs = new WeakReference[n];
                for (int i = 0; i < n; i++) refs[i] = new WeakReference(targets[i]);
                s_keep = new object[] { keep, refs };
                return () =>
                {
                    int i = Rnd(n);
                    object o = new Obj(null) { A = i };
                    targets[i] = o;
                    refs[i] = new WeakReference(o);
                };
            }
            case "wrt":
            {
                WeakReference[] refs = new WeakReference[n];
                for (int i = 0; i < n; i++) refs[i] = new WeakReference(targets[i], true);
                s_keep = new object[] { keep, refs };
                return () =>
                {
                    int i = Rnd(n);
                    object o = new Obj(null) { A = i };
                    targets[i] = o;
                    refs[i] = new WeakReference(o, true);
                };
            }
            case "cwt":
            {
                ConditionalWeakTable<object, object> table = new();
                for (int i = 0; i < n; i++) table.Add(targets[i], new Obj(null) { A = i });
                s_keep = new object[] { keep, table };
                return () =>
                {
                    int i = Rnd(n);
                    object o = new Obj(null) { A = i };
                    table.Remove(targets[i]);
                    targets[i] = o;
                    table.Add(o, new Obj(null) { A = i });
                };
            }
            case "dep":
            {
                DependentHandle[] handles = new DependentHandle[n];
                for (int i = 0; i < n; i++) handles[i] = new DependentHandle(targets[i], new Obj(null) { A = i });
                s_keep = new object[] { keep, handles };
                return () =>
                {
                    int i = Rnd(n);
                    handles[i].Dispose();
                    object o = new Obj(null) { A = i };
                    targets[i] = o;
                    handles[i] = new DependentHandle(o, new Obj(null) { A = i });
                };
            }
            default:
                throw new ArgumentException("unknown handle kind " + kind);
        }
    }

    private static object? s_keep;

    // ---------------------------------------------------------------- 11b
    // N unique string literals in a normal assembly (built by p49genlits.py). Each literal that the JIT resolves is allocated
    // on the frozen object heap. Directory: P49_LIT_DIR/<N>/Literals.dll.
    private static void LoadLiterals(int n)
    {
        if (n == 0) return;
        string dir = Environment.GetEnvironmentVariable("P49_LIT_DIR") ?? "/root/p49/lit";
        long total = 0;
        foreach (string file in Directory.GetFiles(Path.Combine(dir, n.ToString(CultureInfo.InvariantCulture)), "Literals*.dll"))
        {
            Type type = Assembly.LoadFrom(file).GetType("L")!;
            int methods = (int)type.GetProperty("Methods")!.GetValue(null)!;
            for (int m = 0; m < methods; m++) total += (int)type.GetMethod("M" + m)!.Invoke(null, null)!;
        }
        s_checksum += total;
    }

    // ---------------------------------------------------------------- driver
    public static int Main(string[] args)
    {
        string output = args[0];
        string mode = args[1];
        Directory.CreateDirectory(output);
        double seconds = 10;
        int minPauses = 0;
        string description;
        Stopwatch setupWatch = Stopwatch.StartNew();

        Metric? metric = null;
        string? gcPath = Environment.GetEnvironmentVariable("DOTNET_GCPath");
        if (!string.IsNullOrEmpty(gcPath))
        {
            IntPtr library = NativeLibrary.Load(gcPath);
            if (NativeLibrary.TryGetExport(library, "GC_LxrPrototype_GetMetric", out IntPtr export))
                metric = Marshal.GetDelegateForFunctionPointer<Metric>(export);
        }

        PauseListener listener = new PauseListener();
        List<Thread> threads = new();
        Action? hook = null;
        Func<long> mainLoop;
        int liveThreadsRequested = 1;
        ManualResetEventSlim gate = new ManualResetEventSlim(false);
        int ready = 0;
        t_state = 0x9E3779B97F4A7C15UL;

        switch (mode)
        {
            case "bigheap":
            {
                long liveMB = long.Parse(args[2], CultureInfo.InvariantCulture);
                seconds = double.Parse(args[3], CultureInfo.InvariantCulture);
                int rangePerMille = args.Length > 4 ? int.Parse(args[4], CultureInfo.InvariantCulture) : 5;
                int singlePerMille = args.Length > 5 ? int.Parse(args[5], CultureInfo.InvariantCulture) : 95;
                int spin = args.Length > 6 ? int.Parse(args[6], CultureInfo.InvariantCulture) : 0;
                description = $"bigheap liveMB={liveMB} range={rangePerMille} single={singlePerMille} spin={spin}";
                BuildBigHeap(liveMB);
                mainLoop = () => BigHeapLoop(rangePerMille, singlePerMille, spin);
                break;
            }
            case "threads":
            {
                int t = int.Parse(args[2], CultureInfo.InvariantCulture);
                int depth = int.Parse(args[3], CultureInfo.InvariantCulture);
                int allocThreads = int.Parse(args[4], CultureInfo.InvariantCulture);
                seconds = double.Parse(args[5], CultureInfo.InvariantCulture);
                minPauses = args.Length > 6 ? int.Parse(args[6], CultureInfo.InvariantCulture) : 0;
                description = $"threads T={t} depth={depth} allocThreads={allocThreads}";
                for (int k = 0; k < t; k++)
                {
                    Thread thread = new Thread(() => s_checksum += Park(depth, null, gate, ref ready), 8 * 1024 * 1024) { IsBackground = true };
                    thread.Start();
                    threads.Add(thread);
                }
                while (Volatile.Read(ref ready) < t) Thread.Sleep(10);
                for (int k = 0; k < allocThreads - 1; k++)
                {
                    int seed = k + 1;
                    Thread thread = new Thread(() => s_checksum += AllocLoop(seed, null)) { IsBackground = true };
                    threads.Add(thread);
                }
                liveThreadsRequested = t + allocThreads;
                mainLoop = () => AllocLoop(0, null);
                break;
            }
            case "alloc":
            {
                int t = int.Parse(args[2], CultureInfo.InvariantCulture);
                int depth = int.Parse(args[3], CultureInfo.InvariantCulture);
                seconds = double.Parse(args[4], CultureInfo.InvariantCulture);
                minPauses = args.Length > 5 ? int.Parse(args[5], CultureInfo.InvariantCulture) : 0;
                description = $"alloc T={t} depth={depth}";
                for (int k = 0; k < t - 1; k++)
                {
                    int seed = k + 1;
                    Thread thread = new Thread(() => s_checksum += DeepAlloc(depth, null, seed), 8 * 1024 * 1024) { IsBackground = true };
                    threads.Add(thread);
                }
                liveThreadsRequested = t;
                mainLoop = () => DeepAlloc(depth, null, 0);
                break;
            }
            case "handles":
            {
                string kind = args[2];
                int n = int.Parse(args[3], CultureInfo.InvariantCulture);
                seconds = double.Parse(args[4], CultureInfo.InvariantCulture);
                int churn = args.Length > 5 ? int.Parse(args[5], CultureInfo.InvariantCulture) : 1;
                description = $"handles kind={kind} N={n} churn={churn}";
                Action? replace = SetupHandles(kind, n);
                if (replace != null && churn > 0)
                {
                    hook = () => { for (int c = 0; c < churn; c++) replace(); };
                }
                mainLoop = () => AllocLoop(0, hook);
                break;
            }
            case "frozen":
            {
                int n = int.Parse(args[2], CultureInfo.InvariantCulture);
                seconds = double.Parse(args[3], CultureInfo.InvariantCulture);
                description = $"frozen N={n}";
                LoadLiterals(n);
                mainLoop = () => AllocLoop(0, null);
                break;
            }
            default:
                throw new ArgumentException("unknown mode " + mode);
        }
        long setupMs = setupWatch.ElapsedMilliseconds;

        foreach (Thread thread in threads) if (thread.ThreadState == System.Threading.ThreadState.Unstarted) thread.Start();

        // Warm-up: let the code run and the threads settle (also JIT of the loops). The result of this period is not measured.
        Thread controller = new Thread(() => { Thread.Sleep(2000); s_stop = true; }) { IsBackground = true };
        s_stop = false;
        controller.Start();
        if (mode != "threads" && mode != "alloc") mainLoop();
        else Thread.Sleep(2000);
        s_stop = true;
        Thread.Sleep(200);
        s_stop = false;

        using Process process = Process.GetCurrentProcess();
        ulong colsBefore = metric is not null ? metric(5) : (ulong)GC.CollectionCount(0);
        int gen0Before = GC.CollectionCount(0);
        int traceStart = metric is not null ? (int)Math.Min(metric(901), int.MaxValue) : 0;
        double pauseMsBefore = GC.GetTotalPauseDuration().TotalMilliseconds;
        long allocatedBefore = GC.GetTotalAllocatedBytes(false);
        double cpuBefore = process.TotalProcessorTime.TotalMilliseconds;
        DateTime utcStart = DateTime.UtcNow;
        long start = Now();

        Thread stopper = new Thread(() =>
        {
            Thread.Sleep((int)(seconds * 1000));
            // Long pauses (many frames) give few pauses in the window: continue until enough pauses are seen, within a limit.
            int limit = 0;
            while (minPauses > 0 && GC.CollectionCount(0) - gen0Before < minPauses && limit++ < 300) Thread.Sleep(200);
            s_stop = true;
        }) { IsBackground = true };
        stopper.Start();
        long checksum = mainLoop();
        long end = Now();
        DateTime utcEnd = DateTime.UtcNow;

        double cpuAfter = process.TotalProcessorTime.TotalMilliseconds;
        double pauseMsAfter = GC.GetTotalPauseDuration().TotalMilliseconds;
        ulong cols = (metric is not null ? metric(5) : (ulong)GC.CollectionCount(0)) - colsBefore;
        double allocatedMb = (GC.GetTotalAllocatedBytes(false) - allocatedBefore) / (1024.0 * 1024.0);
        int liveThreads = process.Threads.Count;
        long rssKb = StatusKb("VmHWM");

        Thread.Sleep(300);
        var csv = new StringBuilder("start_ms,duration_ms\n");
        DateTime? begin = null;
        lock (listener.Events)
        {
            foreach (var ev in listener.Events)
            {
                if (ev.Id == 9) { begin = ev.Time; }
                else if (begin is not null)
                {
                    if (begin.Value >= utcStart && ev.Time <= utcEnd.AddMilliseconds(50))
                        csv.Append((begin.Value - utcStart).TotalMilliseconds.ToString("F3", CultureInfo.InvariantCulture)).Append(',')
                           .Append((ev.Time - begin.Value).TotalMilliseconds.ToString("F3", CultureInfo.InvariantCulture)).Append('\n');
                    begin = null;
                }
            }
        }
        File.WriteAllText(Path.Combine(output, "pauses.csv"), csv.ToString());
        listener.Dispose();

        long lxrRecords = 0;
        if (metric is not null && Environment.GetEnvironmentVariable("LXR_P49_TRACE") == "1")
        {
            lxrRecords = (long)metric(900); // the library writes the file named by LXR_P49_TRACE_FILE
        }

        File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new
        {
            mode,
            description,
            checksum = checksum + s_checksum,
            is_server_gc = GCSettings.IsServerGC,
            setup_ms = setupMs,
            wall_ms = (end - start) / 1e6,
            cpu_ms = cpuAfter - cpuBefore,
            pause_ms = pauseMsAfter - pauseMsBefore,
            collections = cols,
            gen0 = GC.CollectionCount(0) - gen0Before,
            allocated_mb = allocatedMb,
            peak_rss_mb = rssKb / 1024.0,
            live_threads = liveThreads,
            threads_requested = liveThreadsRequested,
            trace_start = traceStart,
            trace_records = lxrRecords,
        }));
        gate.Set();
        return 0;
    }
}
