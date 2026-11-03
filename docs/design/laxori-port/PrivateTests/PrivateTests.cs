// Laxori private-tier tests (docs/design/laxori-port/DESIGN-v2.md). They need no hook: every thread allocates into a private
// region, and the tests make the thread-local collector, the escape tracking and the dissolve at a pause run by allocating a lot
// of short-lived data around live data. Every node carries a checksum of its own fields, so a stale or moved pointer, a lost
// update and a reused slot show up as a failure. The tests also run on any other GC (the metrics are then absent).
// usage: PrivateTests [test|all] [scale] [threads]      exit code 0 = all passed
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

internal sealed class Node
{
    public long Id;
    public Node? A;
    public Node? B;
    public long[] Data = null!;
    public long Sum;

    [MethodImpl(MethodImplOptions.NoInlining)]
    public static Node Make(long id, Node? a, Node? b)
    {
        var n = new Node { Id = id, A = a, B = b, Data = new long[2 + (int)(id % 5)] };
        for (int i = 0; i < n.Data.Length; i++) n.Data[i] = id * 31 + i;
        n.Sum = n.Compute();
        return n;
    }

    public long Compute()
    {
        long s = Id * 17 + 5;
        foreach (long v in Data) s ^= v + 3;
        s ^= (A?.Id ?? -1) * 7;
        s ^= (B?.Id ?? -2) * 13;
        return s;
    }

    public void Verify(string where)
    {
        if (Data is null || Sum != Compute()) throw new InvalidOperationException("corrupted node id=" + Id + " (" + where + ")");
    }

    // Verifies the whole graph below this node (iterative, bounded by limit nodes).
    public int VerifyGraph(string where, int limit = 100000)
    {
        var stack = new Node[256];
        int sp = 0, count = 0;
        stack[sp++] = this;
        var seen = new HashSet<Node>(ReferenceEqualityComparer.Instance as IEqualityComparer<Node>);
        while (sp > 0 && count < limit)
        {
            Node n = stack[--sp];
            if (!seen.Add(n)) continue;
            n.Verify(where);
            count++;
            if (n.A is not null) { if (sp == stack.Length) Array.Resize(ref stack, sp * 2); stack[sp++] = n.A; }
            if (n.B is not null) { if (sp == stack.Length) Array.Resize(ref stack, sp * 2); stack[sp++] = n.B; }
        }
        return count;
    }
}

internal struct Pair { public Node? A; public long X; public Node? B; }

internal sealed class Fin
{
    public static long Created, Finalized, Bad;
    public readonly Node Held;
    public Fin(Node held) { Held = held; Interlocked.Increment(ref Created); }
    ~Fin()
    {
        try { Held.Verify("finalizer"); } catch { Interlocked.Increment(ref Bad); }
        Interlocked.Increment(ref Finalized);
    }
}

internal sealed class Shared
{
    public Node? Field;
    public Node?[] Array = new Node?[64];
}

internal static unsafe class Program
{
    static delegate* unmanaged[Cdecl]<uint, ulong> s_metric;
    static int s_failures;
    static long s_seed = 20241102;

    static readonly Node?[] s_table = new Node?[512];
    static readonly Pair[] s_pairs = new Pair[256];
    static readonly Shared s_shared = new();
    static Node? s_static;
    [ThreadStatic] static Node? t_static;
    static readonly Dictionary<long, Node> s_dict = new();
    static readonly object s_lock = new();
    static readonly List<Node> s_list = new();

    static int Rnd(ref long st, int n)
    {
        st = st * 6364136223846793005L + 1442695040888963407L;
        return (int)(((ulong)st >> 33) % (ulong)n);
    }

    static void Check(bool ok, string what)
    {
        if (!ok) { Console.Error.WriteLine("FAIL: " + what); Interlocked.Increment(ref s_failures); }
    }

    static ulong Metric(uint i) => s_metric == null ? 0 : s_metric(700 + i);

    // Allocates short-lived data that nothing keeps: this is what fills regions and runs the thread-local collections.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static long Garbage(int count, ref long st)
    {
        long acc = 0;
        for (int i = 0; i < count; i++)
        {
            var g = new Node { Id = i, Data = new long[1 + Rnd(ref st, 6)] };
            acc += g.Data.Length + g.Id;
            if ((i & 63) == 0) { var s = new string('g', 8 + Rnd(ref st, 40)); acc += s.Length; }
        }
        return acc;
    }

    // ---------------------------------------------------------------------------------------------------------------

    // Live objects on the stack (several locals) across a lot of garbage: they are marked from the stack and slide.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestStack(int scale, int thread)
    {
        long st = s_seed + thread;
        for (int round = 0; round < 40 * scale; round++)
        {
            Node a = Node.Make(round * 4L, null, null);
            Node b = Node.Make(round * 4L + 1, a, null);
            Node c = Node.Make(round * 4L + 2, b, a);
            long[] arr = new long[10 + Rnd(ref st, 50)];
            for (int i = 0; i < arr.Length; i++) arr[i] = round + i;
            string s = "s" + round;
            Garbage(3000 + Rnd(ref st, 3000), ref st);
            a.Verify("stack a"); b.Verify("stack b"); c.VerifyGraph("stack c");
            for (int i = 0; i < arr.Length; i++) if (arr[i] != round + i) throw new InvalidOperationException("array corrupted");
            if (s != "s" + round) throw new InvalidOperationException("string corrupted");
            Node d = Node.Make(round + 1000000L, c, b);
            Garbage(1500, ref st);
            d.VerifyGraph("stack d");
        }
    }

    // Interior pointers: refs into fields and array elements, Span<T>, and pinned (fixed) memory, alive across garbage.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestInterior(int scale, int thread)
    {
        long st = s_seed * 3 + thread;
        for (int round = 0; round < 40 * scale; round++)
        {
            Node n = Node.Make(round, null, null);
            long[] arr = new long[40];
            for (int i = 0; i < arr.Length; i++) arr[i] = i * 7L;
            ref long element = ref arr[30 + Rnd(ref st, 10)];
            long expected = element;
            ref long field = ref n.Id;
            Span<long> span = arr.AsSpan(5, 20);
            Garbage(4000, ref st);
            if (element != expected) throw new InvalidOperationException("interior element moved wrong");
            element += 1;
            if (field != round) throw new InvalidOperationException("interior field moved wrong");
            if (span[0] != 35) throw new InvalidOperationException("span moved wrong");
            span[1] = 99;
            if (arr[6] != 99) throw new InvalidOperationException("span aliasing lost");
            n.Sum = n.Compute();
            n.Verify("interior");
            fixed (long* p = arr)
            {
                long* q = p + 10;
                long before = *q;
                Garbage(2500, ref st);
                if (*q != before) throw new InvalidOperationException("pinned memory changed");
                *q = before + 1;
                if (arr[10] != before + 1) throw new InvalidOperationException("pinned address changed");
            }
            long[] other = new long[8];
            fixed (long* p = other)
            {
                Garbage(1000, ref st);
                p[3] = 5;
            }
            if (other[3] != 5) throw new InvalidOperationException("pinned local array");
        }
    }

    // Object graphs of many sizes: small ones fit the survivor limit, big ones do not (the collection is skipped and the
    // region is dissolved).
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestGraph(int scale, int thread)
    {
        long st = s_seed * 5 + thread;
        int[] sizes = { 3, 20, 100, 400, 1500, 6000, 30000 };
        for (int round = 0; round < 12 * scale; round++)
        {
            int size = sizes[round % sizes.Length];
            Node root = BuildGraph(size, ref st);
            Garbage(2000 + Rnd(ref st, 3000), ref st);
            int visited = root.VerifyGraph("graph");
            if (visited != size) throw new InvalidOperationException("graph lost nodes: " + visited + " of " + size);
            Garbage(1000, ref st);
            root.VerifyGraph("graph again");
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static Node BuildGraph(int size, ref long st)
    {
        var nodes = new Node[Math.Min(size, 64)];
        Node last = Node.Make(0, null, null);
        nodes[0] = last;
        for (int i = 1; i < size; i++)
        {
            Node a = nodes[Rnd(ref st, Math.Min(i, nodes.Length))];
            Node b = last;
            Node n = Node.Make(i, a, b);
            nodes[i % nodes.Length] = n;
            last = n;
        }
        return last;
    }

    // Stores of private objects into shared places: they escape (and stay in place in the region, or the region is given to
    // the shared heap). The shared structures are verified all the time.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestEscape(int scale, int thread)
    {
        long st = s_seed * 7 + thread;
        for (int round = 0; round < 200 * scale; round++)
        {
            Node a = Node.Make(thread * 1000000L + round, null, null);
            Node b = Node.Make(thread * 1000000L + round + 500000, a, null);
            switch (Rnd(ref st, 12))
            {
                case 0: s_table[Rnd(ref st, s_table.Length)] = b; break;
                case 1: s_shared.Field = b; break;
                case 2: s_shared.Array[Rnd(ref st, 64)] = a; break;
                case 3: s_static = b; break;
                case 4: t_static = b; break;
                case 5: Interlocked.CompareExchange(ref s_table[Rnd(ref st, s_table.Length)], b, null); break;
                case 6: Interlocked.Exchange(ref s_shared.Field, a); break;
                case 7: lock (s_lock) { s_dict[round % 97] = b; } break;
                case 8: lock (s_lock) { s_list.Add(b); if (s_list.Count > 200) s_list.RemoveRange(0, 100); } break;
                case 9: s_pairs[Rnd(ref st, s_pairs.Length)] = new Pair { A = a, X = round, B = b }; break;
                case 10: { var tmp = new Node?[4]; tmp[0] = a; tmp[1] = b; Array.Copy(tmp, 0, s_table, Rnd(ref st, s_table.Length - 4), 2); } break;
                default: Volatile.Write(ref s_table[Rnd(ref st, s_table.Length)], a); break;
            }
            Garbage(200 + Rnd(ref st, 400), ref st);
            a.Verify("escape a");
            b.VerifyGraph("escape b");
            if ((round & 31) == 0) VerifyShared("escape");
        }
    }

    static ulong BaseMetric(uint i) => s_metric == null ? 0 : s_metric(i);
    static readonly Node?[] s_ring = new Node?[3000];

    // Interaction with the concurrent SATB trace of the shared heap (run with a low DOTNET_LAXORITraceThreshold so that traces run).
    // Every round publishes a new cyclic graph into a shared ring (the old graph becomes cyclic garbage that only the trace can
    // reclaim), keeps the old graph alive only through a private holder across a lot of allocation (a reference that was deleted from
    // the heap while a trace may run: the SATB logging must keep it), and reads random shared graphs back into private objects.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestTrace(int scale, int thread)
    {
        long st = s_seed * 31 + thread;
        for (int round = 0; round < 3000 * scale; round++)
        {
            Node a = Node.Make(thread * 10000000L + round, null, null);
            Node b = Node.Make(thread * 10000000L + round + 5000000, a, null);
            Node c = Node.Make(thread * 10000000L + round + 7000000, b, a);
            a.A = c; a.Sum = a.Compute();      // a cycle a -> c -> b -> a (private stores, no exposure)
            int slot = Rnd(ref st, s_ring.Length);
            Node? old = Interlocked.Exchange(ref s_ring[slot], c);
            Node holder = Node.Make(round, old, null);   // a private object that is the only holder of the deleted graph
            Garbage(200 + Rnd(ref st, 300), ref st);
            holder.Verify("trace holder");
            old?.VerifyGraph("trace old");
            Node? other = s_ring[Rnd(ref st, s_ring.Length)];
            Node reader = Node.Make(9000000L + round, other, null);
            Garbage(100, ref st);
            other?.VerifyGraph("trace other");
            reader.Verify("trace reader");
            if ((round & 255) == 0) foreach (var n in s_ring) n?.VerifyGraph("trace ring");
        }
    }

    static void VerifyShared(string where)
    {
        foreach (var n in s_table) n?.VerifyGraph(where + "/table");
        foreach (var p in s_pairs) { p.A?.Verify(where + "/pairA"); p.B?.VerifyGraph(where + "/pairB"); }
        s_shared.Field?.VerifyGraph(where + "/field");
        foreach (var n in s_shared.Array) n?.VerifyGraph(where + "/array");
        s_static?.VerifyGraph(where + "/static");
        t_static?.VerifyGraph(where + "/tstatic");
        lock (s_lock)
        {
            foreach (var kv in s_dict) kv.Value.VerifyGraph(where + "/dict");
            foreach (var n in s_list) n.VerifyGraph(where + "/list");
        }
    }

    // Copies of reference arrays and of struct arrays that contain references: the bulk-copy callback must escape the
    // private references that are copied into the shared array.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestBulk(int scale, int thread)
    {
        long st = s_seed * 11 + thread;
        var sharedArray = new Node?[128];
        var sharedPairs = new Pair[64];
        lock (s_lock) { s_list.Add(Node.Make(-1, null, null)); }
        for (int round = 0; round < 150 * scale; round++)
        {
            var local = new Node?[16];
            for (int i = 0; i < local.Length; i++) local[i] = Node.Make(round * 100L + i, null, null);
            var localPairs = new Pair[8];
            for (int i = 0; i < localPairs.Length; i++) localPairs[i] = new Pair { A = local[i], X = i, B = local[i + 8] };
            int at = Rnd(ref st, 100);
            Array.Copy(local, 0, sharedArray, at, 16);
            localPairs.AsSpan().CopyTo(sharedPairs.AsSpan(Rnd(ref st, 50)));
            ((Span<Node?>)local).CopyTo(sharedArray.AsSpan(Rnd(ref st, 100)));
            local.AsSpan().Fill(null);   // the shared copies are the only references now
            Array.Clear(localPairs);
            Garbage(1500 + Rnd(ref st, 1500), ref st);
            foreach (var n in sharedArray) n?.Verify("bulk array");
            foreach (var p in sharedPairs) { p.A?.Verify("bulk pairA"); p.B?.Verify("bulk pairB"); }
            Array.Copy(sharedArray, 0, sharedArray, 5, 60);          // overlapping move inside the shared array
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestHandles(int scale, int thread)
    {
        long st = s_seed * 13 + thread;
        var strong = new List<GCHandle>();
        var weak = new List<(GCHandle h, Node keep)>();
        for (int round = 0; round < 100 * scale; round++)
        {
            Node a = Node.Make(round, Node.Make(round + 5000000, null, null), null);
            switch (round % 6)
            {
                case 0: strong.Add(GCHandle.Alloc(a, GCHandleType.Normal)); break;
                case 1: weak.Add((GCHandle.Alloc(a, GCHandleType.Weak), a)); break;
                case 2: weak.Add((GCHandle.Alloc(a, GCHandleType.WeakTrackResurrection), a)); break;
                case 3: { var h = GCHandle.Alloc(a.Data, GCHandleType.Pinned); long addr = (long)h.AddrOfPinnedObject(); Garbage(800, ref st); if ((long)h.AddrOfPinnedObject() != addr) throw new InvalidOperationException("pinned handle moved"); h.Free(); } break;
                case 4: { var cwt = new ConditionalWeakTable<Node, Node>(); var v = Node.Make(round + 9000000, null, null); cwt.Add(a, v); Garbage(1200, ref st); if (!cwt.TryGetValue(a, out var got) || got != v) throw new InvalidOperationException("cwt lost its value"); got.Verify("cwt"); } break;
                default: { var dh = new DependentHandle(a, Node.Make(round + 7000000, null, null)); Garbage(1200, ref st); var (target, dependent) = dh.TargetAndDependent; if (target != a || dependent is null) throw new InvalidOperationException("dependent handle"); ((Node)dependent).Verify("dependent"); dh.Dispose(); } break;
            }
            Garbage(500 + Rnd(ref st, 500), ref st);
            a.VerifyGraph("handles a");
            foreach (var h in strong) { var t = (Node?)h.Target; if (t is null) throw new InvalidOperationException("strong handle lost its target"); t.VerifyGraph("strong handle"); }
            foreach (var (h, keep) in weak) { var t = (Node?)h.Target; if (!ReferenceEquals(t, keep)) throw new InvalidOperationException("weak handle target changed or lost while referenced"); t!.Verify("weak handle"); }
            if (weak.Count > 40) { foreach (var (h, _) in weak) h.Free(); weak.Clear(); }
        }
        foreach (var h in strong) h.Free();
        foreach (var (h, _) in weak) h.Free();
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestFinalizers(int scale, int thread)
    {
        long st = s_seed * 17 + thread;
        for (int round = 0; round < 300 * scale; round++)
        {
            Node a = Node.Make(round, Node.Make(round + 1, null, null), null);
            var f = new Fin(a);
            if (round % 7 == 0) GC.ReRegisterForFinalize(f);
            if (round % 5 == 0) GC.SuppressFinalize(f);
            Garbage(500 + Rnd(ref st, 500), ref st);
            f.Held.VerifyGraph("finalizable");
            GC.KeepAlive(f);
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestCollect(int scale, int thread)
    {
        long st = s_seed * 19 + thread;
        for (int round = 0; round < 6 * scale; round++)
        {
            Node a = Node.Make(round, Node.Make(round + 1, null, null), null);
            Node[] many = new Node[200];
            for (int i = 0; i < many.Length; i++) many[i] = Node.Make(i, i > 0 ? many[i - 1] : null, null);
            Garbage(2000, ref st);
            GC.Collect(0, GCCollectionMode.Forced, true);
            a.VerifyGraph("collect a");
            many[199].VerifyGraph("collect many");
            Garbage(2000, ref st);
            if (round % 3 == 0) GC.Collect();
            a.VerifyGraph("collect a2");
            many[100].VerifyGraph("collect many2");
            s_table[Rnd(ref st, s_table.Length)] = a;
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestSync(int scale, int thread)
    {
        long st = s_seed * 23 + thread;
        for (int round = 0; round < 40 * scale; round++)
        {
            var obj = new object();
            int hash = RuntimeHelpers.GetHashCode(obj);
            Node keep = Node.Make(round, null, null);
            Garbage(2000, ref st);
            lock (obj) { Garbage(300, ref st); }
            if (RuntimeHelpers.GetHashCode(obj) != hash) throw new InvalidOperationException("hash code changed");
            // a second thread contends the lock: the object gets a sync block
            var o2 = new object();
            int h2 = RuntimeHelpers.GetHashCode(o2);
            var t = new Thread(() => { lock (o2) { Thread.Sleep(1); } });
            lock (o2) { t.Start(); Garbage(500, ref st); Thread.Sleep(1); Monitor.Pulse(o2); }
            t.Join();
            Garbage(5000, ref st);
            if (RuntimeHelpers.GetHashCode(o2) != h2) throw new InvalidOperationException("hash code of a locked object changed");
            lock (o2) { }
            keep.Verify("sync");
        }
    }

    // A thread that builds data and hands it to another thread through a queue (the store into the queue escapes it), and
    // threads that leave with live private data.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestHandoff(int scale, int thread)
    {
        long st = s_seed * 29 + thread;
        var queue = new ConcurrentQueue<Node>();
        int produced = 0, consumed = 0;
        int total = 2000 * scale;
        var consumer = new Thread(() =>
        {
            long cst = s_seed;
            while (Volatile.Read(ref consumed) < total)
            {
                if (queue.TryDequeue(out var n)) { n.VerifyGraph("handoff"); Garbage(100, ref cst); n.VerifyGraph("handoff later"); consumed++; }
                else Thread.Yield();
            }
        });
        consumer.Start();
        for (int i = 0; i < total; i++)
        {
            Node n = Node.Make(i, Node.Make(i + 1, null, null), null);
            queue.Enqueue(n);
            Interlocked.Increment(ref produced);
            Garbage(100 + Rnd(ref st, 200), ref st);
            while (queue.Count > 500) Thread.Yield();
        }
        consumer.Join();
        Check(consumed == total, "handoff consumed " + consumed + " of " + total);
        for (int t = 0; t < 8; t++)
        {
            var th = new Thread(() => { long x = s_seed; Node n = Node.Make(1, Node.Make(2, null, null), null); Garbage(1000, ref x); n.VerifyGraph("exiting thread"); });
            th.Start(); th.Join();
        }
    }

    // Many threads at once: each of the other tests, on a few threads.
    static void RunThreads(Action<int, int> test, int scale, int threads)
    {
        var ts = new List<Thread>();
        for (int i = 0; i < threads; i++)
        {
            int index = i;
            var th = new Thread(() =>
            {
                try { test(scale, index); }
                catch (Exception ex) { Console.Error.WriteLine("FAIL: thread " + index + ": " + ex); Interlocked.Increment(ref s_failures); }
            });
            ts.Add(th); th.Start();
        }
        foreach (var th in ts) th.Join();
    }

    // A byref one element past the end of an array (the end pointer of a loop). While the array is alive the byref has to move with it. When
    // nothing else keeps the array, no object contains the address and the collector has to ignore it (it used to be a fatal error).
    [MethodImpl(MethodImplOptions.NoInlining)]
    static ref long EndOf(long[] array) => ref Unsafe.Add(ref MemoryMarshal.GetArrayDataReference(array), array.Length);

    [MethodImpl(MethodImplOptions.NoInlining)]
    static long EndOnly(int length, ref long st)
    {
        ref long end = ref EndOf(new long[length]);
        Garbage(3000, ref st);
        return Unsafe.AsPointer(ref end) == null ? 0 : length;
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static void TestEndRef(int scale, int thread)
    {
        long st = s_seed * 5 + thread;
        for (int round = 0; round < 40 * scale; round++)
        {
            Garbage(1000 + Rnd(ref st, 1000), ref st);
            long[] arr = new long[8 + Rnd(ref st, 40)];
            for (int i = 0; i < arr.Length; i++) arr[i] = round + i;
            ref long end = ref EndOf(arr);
            Garbage(3000 + Rnd(ref st, 3000), ref st);
            long distance = Unsafe.ByteOffset(ref MemoryMarshal.GetArrayDataReference(arr), ref end);
            if (distance != arr.Length * (long)sizeof(long)) throw new InvalidOperationException("end byref did not follow its array");
            long sum = 0;
            for (ref long p = ref MemoryMarshal.GetArrayDataReference(arr); Unsafe.IsAddressLessThan(ref p, ref end); p = ref Unsafe.Add(ref p, 1))
            {
                sum += p;
                if ((sum & 1023) == 1) Garbage(50, ref st);
            }
            long expected = 0;
            for (int i = 0; i < arr.Length; i++) expected += round + i;
            if (sum != expected) throw new InvalidOperationException("loop with an end byref read wrong values");
            EndOnly(4 + Rnd(ref st, 30), ref st);
        }
    }

    static readonly (string name, Action<int, int> body)[] s_tests =
    {
        ("stack", TestStack), ("interior", TestInterior), ("graph", TestGraph), ("escape", TestEscape), ("bulk", TestBulk),
        ("handles", TestHandles), ("finalizers", TestFinalizers), ("collect", TestCollect), ("sync", TestSync), ("handoff", TestHandoff),
        ("trace", TestTrace), ("endref", TestEndRef),
    };

    static int Main(string[] args)
    {
        string which = args.Length > 0 ? args[0] : "all";
        int scale = args.Length > 1 ? int.Parse(args[1]) : 1;
        int threads = args.Length > 2 ? int.Parse(args[2]) : 1;
        string? gc = Environment.GetEnvironmentVariable("DOTNET_GCPath");
        if (!string.IsNullOrEmpty(gc))
        {
            IntPtr lib = NativeLibrary.Load(gc);
            if (NativeLibrary.TryGetExport(lib, "GC_Laxori_GetMetric", out IntPtr m)) s_metric = (delegate* unmanaged[Cdecl]<uint, ulong>)m;
        }
        Console.WriteLine("laxori metrics=" + (s_metric != null) + " scale=" + scale + " threads=" + threads);
        ulong collections0 = Metric(5);
        foreach (var (name, body) in s_tests)
        {
            if (which != "all" && which != name) continue;
            int before = s_failures;
            try
            {
                if (threads <= 1) body(scale, 0); else RunThreads(body, scale, threads);
            }
            catch (Exception ex) { Console.Error.WriteLine("FAIL: " + name + ": " + ex); Interlocked.Increment(ref s_failures); }
            Console.WriteLine((s_failures == before ? "PASS: " : "FAIL: ") + name);
        }
        VerifyShared("final");
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        VerifyShared("after collect");
        Check(Fin.Bad == 0, "a finalizer saw a corrupted object: " + Fin.Bad);
        Check(Fin.Finalized <= Fin.Created, "finalized more than created");
        if (s_metric != null)
        {
            string[] names = { "acquired", "dissolvedPause", "dissolvedFull", "dissolvedEscape", "dissolvedExit", "localCollections", "localSkipped", "markAborted", "notWorth", "survivorBytes", "reclaimedBytes", "escapeCalls", "escapedObjects", "escapedBytes", "foreign", "acquireFailures", "bulkEscapes" };
            for (uint i = 0; i < names.Length; i++) Console.Write(names[i] + "=" + Metric(i) + " ");
            Console.WriteLine();
            Console.WriteLine("trace: initialMarks=" + BaseMetric(10) + " finalMarks=" + BaseMetric(11) + " fullMarks=" + BaseMetric(12) +
                " concurrentSlices=" + BaseMetric(29) + " satbEntries=" + BaseMetric(15) + " cycleObjects=" + BaseMetric(19) + " collections=" + BaseMetric(5));
            if (Environment.GetEnvironmentVariable("PT_EXPECT_TRACE") == "1")
                Check(BaseMetric(10) > 0 && BaseMetric(11) > 0, "no concurrent trace ran (initial " + BaseMetric(10) + ", final " + BaseMetric(11) + ")");
            Check(Metric(14) == 0, "foreign escapes (a reference to a region of another thread)");
            if (Environment.GetEnvironmentVariable("DOTNET_LAXORIPrivate") != "0" && which == "all")
                Check(Metric(5) > collections0, "no thread-local collection ran");
        }
        Console.WriteLine("finalizers created=" + Fin.Created + " finalized=" + Fin.Finalized);
        Console.WriteLine(s_failures == 0 ? "PASS" : "FAILURES=" + s_failures);
        return s_failures == 0 ? 0 : 1;
    }
}
