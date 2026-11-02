// Laxori request tests (docs/design/laxori-port). Each test runs many requests (BeginRequest .. EndRequest), publishes some of
// the request data in a different way, and checks the integrity of everything that was published. The tests also run with
// the hooks absent (any other GC): then they are plain allocation/integrity tests. Exit code 0 = all passed.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

internal sealed class Node
{
    public long Id;
    public long V;
    public long Check;
    public Node? Next;
    public byte[] Payload = null!;

    public static Node Make(long id, long v, Node? next)
    {
        var n = new Node { Id = id, V = v, Next = next, Payload = new byte[24 + (int)(v & 31)] };
        n.Payload[0] = (byte)v;
        n.Check = Compute(n);
        return n;
    }
    public static long Compute(Node n) => n.Id * 31 ^ n.V ^ n.Payload[0] ^ n.Payload.Length;
    public void Validate(string where)
    {
        if (Payload is null || Check != Compute(this)) throw new InvalidOperationException("corrupted node (" + where + ") id=" + Id);
        for (Node? c = Next; c is not null; c = c.Next)
            if (c.Payload is null || c.Check != Compute(c)) throw new InvalidOperationException("corrupted chain (" + where + ") id=" + Id);
    }
}

internal struct Pair { public Node? A; public Node? B; public long Tag; }

internal sealed class Fin
{
    public static long Created, Finalized, Bad;
    public long Id; public Node Held;
    public Fin(long id, Node held) { Id = id; Held = held; Interlocked.Increment(ref Created); }
    ~Fin()
    {
        if (Held is null || Held.Check != Node.Compute(Held)) Interlocked.Increment(ref Bad);
        Interlocked.Increment(ref Finalized);
    }
}

internal static unsafe class Program
{
    static delegate* unmanaged[Cdecl, SuppressGCTransition]<void> s_begin;
    static delegate* unmanaged[Cdecl, SuppressGCTransition]<void*, void> s_end;
    static delegate* unmanaged[Cdecl]<uint, ulong> s_metric;
    static bool s_hooks;

    static void Begin() { if (s_begin != null) s_begin(); }
    static void End() { if (s_end != null) s_end(null); }
    static void EndWith(object? result)
    {
        if (s_end == null) return;
        nint p = result is null ? 0 : Unsafe.As<object, nint>(ref result);
        s_end((void*)p);
    }

    static readonly Node?[] s_table = new Node?[1024];
    static readonly object?[] s_objs = new object?[1024];
    static readonly Pair[] s_pairs = new Pair[1024];
    static readonly Node?[] s_big = new Node?[20000]; // 160 KB: large object space
    static Node? s_static;
    static readonly Dictionary<long, Node> s_dict = new();
    static readonly object s_dictLock = new();
    static long s_seed = 12345;
    static int s_failures;

    static int Rnd(ref long state, int n)
    {
        state = state * 6364136223846793005L + 1442695040888963407L;
        return (int)(((ulong)state >> 33) % (ulong)n);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static Node Build(long id, int count)
    {
        Node? head = null;
        for (int i = 0; i < count; i++) head = Node.Make(id, id * 7 + i, head);
        return head!;
    }

    static void Check(bool ok, string what)
    {
        if (!ok) { Console.Error.WriteLine("FAIL: " + what); Interlocked.Increment(ref s_failures); }
    }

    static void ValidateAll(string where)
    {
        foreach (var n in s_table) n?.Validate(where + "/table");
        foreach (var o in s_objs) if (o is Node n) n.Validate(where + "/objs");
        foreach (var p in s_pairs) { p.A?.Validate(where + "/pairA"); p.B?.Validate(where + "/pairB"); }
        foreach (var n in s_big) n?.Validate(where + "/big");
        s_static?.Validate(where + "/static");
        lock (s_dictLock) foreach (var kv in s_dict) kv.Value.Validate(where + "/dict");
    }

    // 1. Stores of request objects into shared arrays, a static field, a struct array and a large array.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void RequestStores(ref long st, long id)
    {
        Node a = Build(id, 4 + Rnd(ref st, 6));
        Node b = Build(id + 1, 3);
        int k = Rnd(ref st, 8);
        if (k == 0) s_table[Rnd(ref st, s_table.Length)] = a;
        else if (k == 1) s_objs[Rnd(ref st, s_objs.Length)] = b;
        else if (k == 2) s_pairs[Rnd(ref st, s_pairs.Length)] = new Pair { A = a, B = b, Tag = id };
        else if (k == 3) s_big[Rnd(ref st, s_big.Length)] = a.Next ?? a;
        else if (k == 4) s_static = b;
        else if (k == 5) { object? old = Interlocked.CompareExchange(ref s_objs[Rnd(ref st, s_objs.Length)], b, null); _ = old; }
        else if (k == 6) { var tmp = new Node?[4]; tmp[0] = a; tmp[1] = b; Array.Copy(tmp, 0, s_table, Rnd(ref st, s_table.Length - 4), 2); }
        else lock (s_dictLock) { s_dict[id % 257] = a; }
    }

    // 2. Handles of every kind.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void RequestHandles(ref long st, long id, List<GCHandle> keep, List<GCHandle> weak)
    {
        Node a = Build(id, 3);
        int k = Rnd(ref st, 4);
        if (k == 0) lock (keep) keep.Add(GCHandle.Alloc(a, GCHandleType.Normal));
        else if (k == 1) lock (weak) weak.Add(GCHandle.Alloc(a, GCHandleType.Weak));
        else if (k == 2) { var h = GCHandle.Alloc(new byte[64], GCHandleType.Pinned); h.Free(); lock (weak) weak.Add(GCHandle.Alloc(a, GCHandleType.WeakTrackResurrection)); }
        else { var cwt = new ConditionalWeakTable<Node, Node>(); var m = Build(id + 5, 2); cwt.Add(a, m); if (!cwt.TryGetValue(a, out var got) || got != m) Check(false, "cwt"); }
    }

    // 3. Finalizable objects that hold request data.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void RequestFinalizable(long id)
    {
        Node a = Build(id, 3);
        var f = new Fin(id, a);
        GC.KeepAlive(f);
    }

    // 4. A request that calls GC.Collect (a pause in the middle of a request) and keeps using its objects.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void RequestWithCollect(ref long st, long id)
    {
        Node a = Build(id, 8);
        GC.Collect(0, GCCollectionMode.Forced, true);
        Node b = Build(id + 1, 8);
        a.Validate("collect/a");
        b.Validate("collect/b");
        s_table[Rnd(ref st, s_table.Length)] = Rnd(ref st, 2) == 0 ? a : b;
        a.Validate("collect/a2");
    }

    // 5. A request that returns its result: EndRequest publishes it.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static Node RequestResult(long id) => Build(id, 5);

    // 6. Objects that must not be allocated in the region, and large request objects.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void RequestMixedSizes(ref long st, long id)
    {
        Node a = Build(id, 2);
        var arr = new object[2000]; // 16 KB: above the private object limit
        arr[0] = a;
        var small = new long[100];
        small[3] = id;
        var big = new Node?[5000]; // 40 KB: large object space
        big[Rnd(ref st, big.Length)] = a;
        if (arr[0] != a || small[3] != id) Check(false, "mixed sizes");
        if (Rnd(ref st, 4) == 0) s_big[Rnd(ref st, s_big.Length)] = a;
        string s = new string('x', 100 + (int)(id & 63)) + id;
        if (s.Length < 100) Check(false, "string");
    }

    static void Worker(int index, int iterations, List<GCHandle> keep, List<GCHandle> weak, ConcurrentBag<Node> results)
    {
        long st = s_seed + index * 1000003L;
        for (int i = 0; i < iterations; i++)
        {
            long id = ((long)index << 40) + i;
            Begin();
            switch (Rnd(ref st, 14))
            {
                case 0: case 1: case 2: case 3: RequestStores(ref st, id); End(); break;
                case 4: case 5: RequestHandles(ref st, id, keep, weak); End(); break;
                case 6: RequestFinalizable(id); End(); break;
                case 7: if (Rnd(ref st, 50) == 0) RequestWithCollect(ref st, id); else RequestStores(ref st, id); End(); break;
                case 8: { Node r = RequestResult(id); EndWith(r); r.Validate("result"); if (Rnd(ref st, 3) == 0) results.Add(r); break; }
                case 9: RequestMixedSizes(ref st, id); End(); break;
                case 10: Begin(); RequestStores(ref st, id); End(); break; // nested begin: the first request is published
                case 11: End(); End(); break; // end without a body
                default: RequestStores(ref st, id); End(); break;
            }
            if ((i & 1023) == 0) ValidateAll("worker" + index);
        }
    }

    static int Main(string[] args)
    {
        int threads = args.Length > 0 ? int.Parse(args[0]) : 4;
        int iterations = args.Length > 1 ? int.Parse(args[1]) : 100000;
        string? gc = Environment.GetEnvironmentVariable("DOTNET_GCPath");
        if (!string.IsNullOrEmpty(gc))
        {
            IntPtr lib = NativeLibrary.Load(gc);
            if (NativeLibrary.TryGetExport(lib, "GC_Laxori_BeginRequest", out IntPtr b) && NativeLibrary.TryGetExport(lib, "GC_Laxori_EndRequest", out IntPtr e))
            {
                s_begin = (delegate* unmanaged[Cdecl, SuppressGCTransition]<void>)b;
                s_end = (delegate* unmanaged[Cdecl, SuppressGCTransition]<void*, void>)e;
                s_hooks = true;
                if (NativeLibrary.TryGetExport(lib, "GC_Laxori_GetMetric", out IntPtr m)) s_metric = (delegate* unmanaged[Cdecl]<uint, ulong>)m;
            }
        }
        Console.WriteLine("hooks=" + s_hooks + " threads=" + threads + " iterations=" + iterations);
        var keep = new List<GCHandle>();
        var weak = new List<GCHandle>();
        var results = new ConcurrentBag<Node>();
        var ts = new List<Thread>();
        for (int t = 0; t < threads; t++)
        {
            int index = t;
            var th = new Thread(() =>
            {
                try { Worker(index, iterations, keep, weak, results); }
                catch (Exception ex) { Console.Error.WriteLine("FAIL: worker " + index + ": " + ex); Interlocked.Increment(ref s_failures); }
            });
            ts.Add(th); th.Start();
        }
        // A thread that exits inside a request, after it published and after it did not.
        for (int t = 0; t < 40; t++)
        {
            int index = 100 + t;
            var th = new Thread(() =>
            {
                long st = s_seed + index;
                Begin();
                if ((index & 1) == 0) RequestStores(ref st, index); else { Node n = Build(index, 5); n.Validate("exit"); }
                // no EndRequest: the thread ends in a request
            });
            th.Start(); th.Join();
        }
        foreach (var th in ts) th.Join();
        ValidateAll("final");
        foreach (var h in keep) { var n = (Node?)h.Target; if (n is null) Check(false, "strong handle lost its target"); else n.Validate("strong handle"); }
        foreach (var h in weak) ((Node?)h.Target)?.Validate("weak handle");
        foreach (var n in results) n.Validate("results");
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        ValidateAll("after collect");
        foreach (var h in keep) { var n = (Node?)h.Target; if (n is null) Check(false, "strong handle lost its target after collect"); else n.Validate("strong handle 2"); }
        Check(Fin.Bad == 0, "finalizer saw a corrupted object: " + Fin.Bad);
        Check(Fin.Finalized <= Fin.Created, "finalized more than created");
        Console.WriteLine("finalizers created=" + Fin.Created + " finalized=" + Fin.Finalized);
        if (s_metric != null)
        {
            string[] names = { "begun", "ended", "reset", "resetBytes", "pubEscape", "pubFull", "pubPause", "acquired", "escapeCalls", "foreign" };
            for (uint i = 0; i < names.Length; i++) Console.Write(names[i] + "=" + s_metric(700 + i) + " ");
            Console.WriteLine();
            Check(s_metric(709) == 0, "foreign escapes (a reference to a region of another thread)");
        }
        Console.WriteLine(s_failures == 0 ? "PASS" : "FAILURES=" + s_failures);
        return s_failures == 0 ? 0 : 1;
    }
}
