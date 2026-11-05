using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Text.Json;

internal static class CompareDriver
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

    private const int TimerCount = 77;
    private const int SchedulerCount = 7;

    [DllImport("libc")]
    private static extern int clock_gettime(int clock, out Timespec value);

    private struct Timespec
    {
        public long Seconds;
        public long Nanoseconds;
    }

    private static long Now()
    {
        if (clock_gettime(1, out Timespec value) != 0)
            throw new InvalidOperationException("clock_gettime failed.");
        return checked(value.Seconds * 1_000_000_000 + value.Nanoseconds);
    }

    private static long StatusKb(string key)
    {
        foreach (string line in File.ReadLines("/proc/self/status"))
        {
            if (line.StartsWith(key, StringComparison.Ordinal))
                return long.Parse(new string(Array.FindAll(line.ToCharArray(), char.IsDigit)), CultureInfo.InvariantCulture);
        }
        return -1;
    }

    public static int Main(string[] args)
    {
        if (Environment.GetEnvironmentVariable("JITCOUNT") == "1") Console.Error.WriteLine("JITCOUNT at Main start: " + System.Runtime.JitInfo.GetCompiledMethodCount(false));
        string? lateTls = Environment.GetEnvironmentVariable("DRV_LATE_TLS");
        if (!string.IsNullOrEmpty(lateTls)) { NativeLibrary.Load(lateTls); }
        string output = args[0];
        string workload = args[1];
        int size = int.Parse(args[2], CultureInfo.InvariantCulture);
        long operations = long.Parse(args[3], CultureInfo.InvariantCulture);
        Directory.CreateDirectory(output);

        string? gcPath = Environment.GetEnvironmentVariable("DOTNET_GCPath");
        Metric? metric = null;
        if (!string.IsNullOrEmpty(gcPath))
        {
            IntPtr library = NativeLibrary.Load(gcPath);
            if (NativeLibrary.TryGetExport(library, "GC_LxrPrototype_GetMetric", out IntPtr export))
            {
                metric = Marshal.GetDelegateForFunctionPointer<Metric>(export);
            }
        }

        MethodInfo run = typeof(GcBench).GetMethod("Run", BindingFlags.Static | BindingFlags.NonPublic)!;
        FieldInfo state = typeof(GcBench).GetField("s_state", BindingFlags.Static | BindingFlags.NonPublic)!;
        long Invoke(int count, long ops)
        {
            state.SetValue(null, 0x9E3779B97F4A7C15UL);
            return (long)run.Invoke(null, new object?[] { workload, count, ops, null, false })!;
        }

        PauseListener? pauseListener = Environment.GetEnvironmentVariable("DRV_PAUSES") == "1" ? new PauseListener() : null;
        Stopwatch warmup = Stopwatch.StartNew();
        do
        {
            Invoke(workload == "binarytrees" ? Math.Min(size, 14) : Math.Min(size, 4096), workload == "losmany" ? 300 : 20000);
        } while (warmup.Elapsed.TotalSeconds < 3);
        warmup.Stop();

        ulong lxrColsBefore = metric is not null ? metric(5) : 0;
        ulong lxrCopiedBefore = metric is not null ? metric(80) : 0;
        ulong lxrPauseTicksBefore = metric is not null ? metric(241) : 0;
        ulong[] timerBefore = new ulong[TimerCount];
        ulong[] schedBefore = new ulong[SchedulerCount];
        if (metric is not null)
        {
            for (uint i = 0; i < TimerCount; i++) timerBefore[i] = metric(340 + i);
            for (uint i = 0; i < SchedulerCount; i++) schedBefore[i] = metric(500 + i);
        }
        ulong[] item4Before = new ulong[7];
        const int ExpCount = 27;
        bool exp = metric is not null && Environment.GetEnvironmentVariable("DRV_EXP") == "1";
        ulong[] expBefore = new ulong[ExpCount];
        if (exp) { for (uint i = 0; i < ExpCount; i++) expBefore[i] = metric!(700 + i); }
        bool item4 = metric is not null && Environment.GetEnvironmentVariable("DRV_ITEM4") == "1";
        if (item4)
        {
            for (uint i = 0; i < 7; i++) item4Before[i] = metric!(640 + i);
        }
        long allocatedBefore = GC.GetTotalAllocatedBytes(false);
        ulong[] causeBefore = new ulong[8];
        if (metric is not null)
        {
            for (uint i = 0; i < 8; i++) causeBefore[i] = metric(520 + i);
        }
        int gen0Before = GC.CollectionCount(0);
        int gen1Before = GC.CollectionCount(1);
        int gen2Before = GC.CollectionCount(2);
        double pauseMsBefore = GC.GetTotalPauseDuration().TotalMilliseconds;

        using Process process = Process.GetCurrentProcess();
        double cpuBefore = process.TotalProcessorTime.TotalMilliseconds;
        string? mark = Environment.GetEnvironmentVariable("PROF_MARK"); if (mark is not null) File.WriteAllText(mark + ".start", "1");
        ulong m33a = metric is not null ? metric(33) : 0;
        DateTime utcStart = DateTime.UtcNow;
        ulong[] mBefore = new ulong[260]; if (metric is not null && Environment.GetEnvironmentVariable("DRV_METRICS")=="1") for (uint i=0;i<260;i++) mBefore[i]=metric(i);
        long start = Now();
        long checksum = Invoke(size, operations);
        long end = Now();
        DateTime utcEnd = DateTime.UtcNow;
        if (pauseListener is not null)
        {
            System.Threading.Thread.Sleep(300);
            var csv = new System.Text.StringBuilder("start_ms,duration_ms\n");
            DateTime? begin = null;
            lock (pauseListener.Events)
            {
                foreach (var ev in pauseListener.Events)
                {
                    if (ev.Id == 9) { begin = ev.Time; }
                    else if (begin is not null)
                    {
                        if (begin.Value >= utcStart && ev.Time <= utcEnd.AddMilliseconds(50))
                            csv.Append(((begin.Value - utcStart).TotalMilliseconds).ToString("F3", CultureInfo.InvariantCulture)).Append(',').Append((ev.Time - begin.Value).TotalMilliseconds.ToString("F3", CultureInfo.InvariantCulture)).Append('\n');
                        begin = null;
                    }
                }
            }
            File.WriteAllText(Path.Combine(output, "pauses.csv"), csv.ToString());
            pauseListener.Dispose();
        }
        if (mark is not null) File.WriteAllText(mark + ".end", "1");
        if (metric is not null) Console.Error.WriteLine("fast_refills=" + (metric(33) - m33a));
        if (metric is not null && Environment.GetEnvironmentVariable("DRV_METRICS")=="1") { var d=new System.Text.StringBuilder("METRICS"); foreach (uint i in new uint[]{1,2,5,8,9,10,11,12,13,14,15,16,19,20,23,24,79,80,95,96,98,100}) d.Append(" m"+i+"="+(long)(metric(i)-mBefore[i])); Console.Error.WriteLine(d.ToString()); }
        double cpuAfter = process.TotalProcessorTime.TotalMilliseconds;

        double pauseMsAfter = GC.GetTotalPauseDuration().TotalMilliseconds;
        int gen0 = GC.CollectionCount(0) - gen0Before;
        int gen1 = GC.CollectionCount(1) - gen1Before;
        int gen2 = GC.CollectionCount(2) - gen2Before;
        ulong lxrCols = metric is not null ? metric(5) - lxrColsBefore : 0;
        ulong lxrCopiedBytes = metric is not null ? metric(80) - lxrCopiedBefore : 0;
        ulong lxrPauseTicks = metric is not null ? metric(241) - lxrPauseTicksBefore : 0;
        long rssKb = StatusKb("VmHWM");
        ulong[] timerDelta = new ulong[TimerCount];
        ulong[] schedDelta = new ulong[SchedulerCount];
        if (metric is not null)
        {
            for (uint i = 0; i < TimerCount; i++) timerDelta[i] = metric(340 + i) - timerBefore[i];
            for (uint i = 0; i < SchedulerCount; i++) schedDelta[i] = metric(500 + i) - schedBefore[i];
        }
        long totalCollections = metric is not null ? (long)metric(5) : GC.CollectionCount(0);
        long[] item4Delta = new long[7];
        long[] expDelta = new long[ExpCount];
        if (exp) { for (uint i = 0; i < ExpCount; i++) expDelta[i] = (long)(metric!(700 + i) - expBefore[i]); }
        if (item4)
        {
            for (uint i = 0; i < 7; i++) item4Delta[i] = (long)(metric!(640 + i) - item4Before[i]);
        }
        long[] causes = new long[8];
        if (metric is not null)
        {
            for (uint i = 0; i < 8; i++) causes[i] = (long)(metric(520 + i) - causeBefore[i]);
        }
        double allocatedMb = (GC.GetTotalAllocatedBytes(false) - allocatedBefore) / (1024.0 * 1024.0);

        File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new {
            workload,
            size,
            operations,
            checksum,
            is_server_gc = GCSettings.IsServerGC,
            wall_ms = (end - start) / 1e6,
            cpu_ms = cpuAfter - cpuBefore,
            pause_ms = pauseMsAfter - pauseMsBefore,
            collections = metric is not null ? (long)lxrCols : gen0,
            gen0,
            gen1,
            gen2,
            lxr_copied_mb = lxrCopiedBytes / (1024.0 * 1024.0),
            peak_rss_mb = rssKb / 1024.0,
            total_collections = totalCollections,
            allocated_mb = allocatedMb,
            item4 = item4Delta,
            exp = expDelta,
            causes,
            timer_ns = timerDelta,
            scheduler = schedDelta
        }));
        return 0;
    }
}
