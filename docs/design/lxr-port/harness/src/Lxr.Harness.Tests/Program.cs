// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.IO;
using Lxr.Harness.Core;
using Lxr.Harness.Runner;
using Lxr.Harness.Scenarios;
using static Lxr.Harness.Tests.TestRunner;

Console.WriteLine("Lxr.Harness.Tests");
Console.WriteLine();

Console.WriteLine("Stats.Percentile");
Test("nearest rank picks a real sample, never an interpolated one", () =>
{
    double[] sorted = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    Equal(1.0, Stats.Percentile(sorted, 0), "the 0th percentile is the smallest sample");
    Equal(5.0, Stats.Percentile(sorted, 50), "nearest rank at 50% of 10 samples is rank 5");
    Equal(10.0, Stats.Percentile(sorted, 100), "the 100th percentile is the largest sample");
    Equal(10.0, Stats.Percentile(sorted, 99.99), "a percentile finer than the sample count saturates at the maximum");
});

Test("a single sample answers every percentile", () =>
{
    double[] one = [42];
    Equal(42.0, Stats.Percentile(one, 0), "0th");
    Equal(42.0, Stats.Percentile(one, 99.99), "99.99th");
});

Test("an empty sample is NaN rather than zero", () =>
{
    // Zero would read as an excellent latency. NaN propagates into the report instead.
    True(double.IsNaN(Stats.Percentile([], 99)), "an empty distribution has no 99th percentile");
});

Test("an out-of-range percentile is rejected", () =>
{
    Throws<ArgumentOutOfRangeException>(() => Stats.Percentile([1], 101), "above 100");
    Throws<ArgumentOutOfRangeException>(() => Stats.Percentile([1], -1), "below 0");
});

Console.WriteLine();
Console.WriteLine("Stats.BootstrapRatio");
Test("identical arms give a ratio of 1.0 with an interval containing it", () =>
{
    double[] a = [100, 101, 99, 100, 102, 98, 100, 101, 99];
    RatioEstimate estimate = Stats.BootstrapRatio(a, a);
    Close(1.0, estimate.Ratio, 1e-9, "the same data compared with itself is exactly 1.0");
    False(estimate.ExcludesUnity, "an interval on identical arms must not claim a difference");
});

Test("a large separation is resolved", () =>
{
    double[] baseline = [100, 101, 99, 100, 102, 98, 100];
    double[] candidate = [200, 201, 199, 200, 202, 198, 200];
    RatioEstimate estimate = Stats.BootstrapRatio(baseline, candidate);
    Close(2.0, estimate.Ratio, 0.05, "candidate is twice baseline");
    True(estimate.ExcludesUnity, "a 2x difference must be resolvable");
});

Test("wide overlapping arms are NOT resolved", () =>
{
    // The direction that matters. An estimator that always excludes 1.0 would make control 7
    // meaningless and every ratio in a report a false positive.
    double[] baseline = [50, 150, 60, 140, 55, 145, 70];
    double[] candidate = [52, 148, 63, 139, 58, 143, 68];
    RatioEstimate estimate = Stats.BootstrapRatio(baseline, candidate);
    False(estimate.ExcludesUnity, "arms this noisy must not be declared different");
});

Test("the interval is reproducible for a given seed", () =>
{
    double[] baseline = [10, 12, 11, 13, 9, 14, 10];
    double[] candidate = [11, 13, 12, 14, 10, 15, 11];
    RatioEstimate first = Stats.BootstrapRatio(baseline, candidate, seed: 7);
    RatioEstimate second = Stats.BootstrapRatio(baseline, candidate, seed: 7);
    Equal(first.Low, second.Low, "the same seed must give the same lower bound");
    Equal(first.High, second.High, "the same seed must give the same upper bound");

    RatioEstimate other = Stats.BootstrapRatio(baseline, candidate, seed: 8);
    True(other.Low != first.Low || other.High != first.High, "a different seed must actually resample differently");
});

Test("half-width is a fraction of the point estimate", () =>
{
    var estimate = new RatioEstimate(2.0, 1.8, 2.2, 100);
    Close(0.1, estimate.HalfWidthFraction, 1e-12, "(2.2-1.8)/2/2.0 = 0.1");
});

Test("an empty arm is rejected rather than producing a NaN ratio", () =>
{
    Throws<ArgumentOutOfRangeException>(() => Stats.BootstrapRatio([], [1, 2, 3]), "empty baseline");
    Throws<ArgumentOutOfRangeException>(() => Stats.BootstrapRatio([1, 2, 3], []), "empty candidate");
});

Console.WriteLine();
Console.WriteLine("Stats.GeometricMean");
Test("geometric mean matches the hand-computed value", () =>
{
    Close(2.0, Stats.GeometricMean([1, 2, 4]), 1e-9, "cube root of 8");
    True(double.IsNaN(Stats.GeometricMean([1, 0, 4])), "a zero has no geometric mean");
    True(double.IsNaN(Stats.GeometricMean([1, -2, 4])), "a negative has no geometric mean");
});

Test("geometric and arithmetic means differ, which is why the choice is recorded", () =>
{
    // P0.2 section 7's barrier figure is a geometric mean. Rolling up with an arithmetic mean would
    // silently disagree with the number being compared against.
    double[] ratios = [0.5, 2.0];
    Close(1.0, Stats.GeometricMean(ratios), 1e-9, "geometric mean of 0.5 and 2.0 is 1.0");
    Close(1.25, Stats.Mean(ratios), 1e-9, "arithmetic mean of the same pair is 1.25");
});

Console.WriteLine();
Console.WriteLine("SampleStore");
Test("raw samples round-trip through the compressed store", () =>
{
    string path = Path.Combine(Path.GetTempPath(), $"lxr-samples-{Guid.NewGuid():N}.bin.gz");
    try
    {
        var records = new OperationRecord[3];
        for (int i = 0; i < records.Length; i++)
        {
            records[i] = new OperationRecord
            {
                IntendedTimestamp = 1000 + i,
                ServiceStartTimestamp = 1005 + i,
                EndTimestamp = 1020 + i,
                Value = 7 * i,
                Phase = i == 0 ? 0 : 1,
            };
        }

        var run = new MeasuredRun
        {
            Records = records,
            RecordCount = records.Length,
            SteadyStateCount = 2,
            RequestedRatePerSecond = 1000,
            AchievedRatePerSecond = 999.7,
            LateCount = 0,
            BacklogMax = 1,
            Overloaded = false,
            Checksum = 21,
            WallSeconds = 1.5,
        };
        SampleStore.WriteOpenLoop(path, run, runStartTimestamp: 1000);

        (long frequency, OperationRecord[] read) = SampleStore.ReadOpenLoop(path);
        Equal(System.Diagnostics.Stopwatch.Frequency, frequency, "the frequency is stored so ticks need no guessing");
        Equal(3, read.Length, "all three records come back");
        Equal(0L, read[0].IntendedTimestamp, "timestamps are stored relative to the run start");
        Equal(20L, read[0].EndTimestamp, "end timestamp survives the round trip");
        Equal(14L, read[2].Value, "the operation value survives the round trip");
        Equal(0, read[0].Phase, "the warmup phase marker survives, so the boundary can be re-chosen later");
        Equal(1, read[1].Phase, "the steady-state phase marker survives");
    }
    finally
    {
        File.Delete(path);
    }
});

Test("a file that is not a sample store is rejected", () =>
{
    string path = Path.Combine(Path.GetTempPath(), $"lxr-notsamples-{Guid.NewGuid():N}.bin.gz");
    try
    {
        File.WriteAllText(path, "this is not a sample file");
        Throws<Exception>(() => SampleStore.ReadOpenLoop(path), "a foreign file must not be read as samples");
    }
    finally
    {
        File.Delete(path);
    }
});

Console.WriteLine();
Console.WriteLine("MatrixPlanner.InterleavedOrder");
Test("arms alternate rather than blocking", () =>
{
    List<(MatrixCell Cell, int Invocation)> order = MatrixPlanner.InterleavedOrder(TwoArmCells(3), seed: 1);
    Equal(6, order.Count, "three invocations of two arms");
    for (int round = 0; round < 3; round++)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal)
        {
            order[round * 2].Cell.Arm.Id,
            order[(round * 2) + 1].Cell.Arm.Id,
        };

        Equal(2, seen.Count, $"round {round} must contain both arms, not the same arm twice");
        Equal(round, order[round * 2].Invocation, "invocation index advances one round at a time");
        Equal(round, order[(round * 2) + 1].Invocation, "both arms are at the same invocation index");
    }
});

Test("arm order within a round is shuffled, not fixed", () =>
{
    // All-A-then-all-B would let thermal drift masquerade as an effect, and so would a fixed A,B,A,B
    // in which A always warms the caches for B.
    var firstPositions = new HashSet<string>(StringComparer.Ordinal);
    for (int seed = 0; seed < 20; seed++)
    {
        List<(MatrixCell Cell, int Invocation)> order = MatrixPlanner.InterleavedOrder(TwoArmCells(4), seed);
        for (int round = 0; round < 4; round++)
        {
            firstPositions.Add(order[round * 2].Cell.Arm.Id);
        }
    }

    Equal(2, firstPositions.Count, "both arms must appear first sometimes, or the shuffle does nothing");
});

Test("the order is reproducible for a given seed", () =>
{
    List<(MatrixCell Cell, int Invocation)> a = MatrixPlanner.InterleavedOrder(TwoArmCells(4), seed: 99);
    List<(MatrixCell Cell, int Invocation)> b = MatrixPlanner.InterleavedOrder(TwoArmCells(4), seed: 99);
    for (int i = 0; i < a.Count; i++)
    {
        Equal(a[i].Cell.Id, b[i].Cell.Id, $"position {i} must be identical for the same seed");
        Equal(a[i].Invocation, b[i].Invocation, $"position {i} invocation must be identical for the same seed");
    }
});

Test("a tag makes two otherwise identical cells distinct", () =>
{
    // The defect this guards against was real. Every control reused one cell id, so a crash dump
    // written by control 5 was still on disk when control 7 launched and was attributed to it,
    // marking a clean run as crashed and silently dropping a good measurement out of the interval.
    string untagged = Cell(CollectorArms.Workstation, 1, tag: null).Id;
    string tagged = Cell(CollectorArms.Workstation, 1, tag: "c5").Id;
    True(tagged != untagged, "a tag must change the cell id, or per-control artifacts collide");
});

Console.WriteLine();
Console.WriteLine("ScenarioCatalog");
Test("the catalogue holds the ten scenarios the brief specifies", () =>
{
    Equal(10, ScenarioCatalog.All.Count, "ten scenarios, no more and no fewer");
});

Test("every catalogued scenario has a timeout and an implementation in the right assembly", () =>
{
    foreach (ScenarioCatalog.Entry entry in ScenarioCatalog.All)
    {
        True(entry.DefaultTimeoutSeconds > 0, $"{entry.Id} must declare a timeout");

        bool needsAspNet = (entry.RequiredCapabilities & HostCapabilities.AspNetCoreSharedFramework) != 0;
        bool inSharedRegistry = ScenarioRegistry.TryCreate(entry.Id, out _);

        // The split is deliberate. Lxr.Harness.Scenarios must not carry an ASP.NET framework
        // reference or it could not load on a CoreRun host at all, so the one scenario that needs
        // Kestrel lives in the separate ASP.NET worker and is absent from this registry by design.
        // Asserting the correspondence rather than mere presence is what makes that a decision
        // instead of an oversight.
        Equal(!needsAspNet, inSharedRegistry, $"{entry.Id}: ASP.NET scenarios belong to the ASP.NET worker, all others to the shared registry");
    }
});

Test("every registered implementation is catalogued", () =>
{
    // The reverse direction. An implementation with no catalogue entry would have no timeout, no
    // declared capability requirement and no place in the matrix, yet would still be launchable.
    foreach (string id in ScenarioRegistry.Ids)
    {
        True(ScenarioCatalog.Find(id) is not null, $"{id} is implemented but not catalogued");
    }
});

Test("at least one latency-primary scenario runs without ASP.NET", () =>
{
    // The gate asserts this too. It matters because the flagship scenario cannot reach a CoreRun
    // host, so without this the future LXR arm would have no application-latency evidence at all.
    bool any = false;
    foreach (ScenarioCatalog.Entry entry in ScenarioCatalog.All)
    {
        if (entry.SupportsLatency && (entry.RequiredCapabilities & HostCapabilities.AspNetCoreSharedFramework) == 0)
        {
            any = true;
            break;
        }
    }

    True(any, "every host must be able to produce some open-loop latency evidence");
});

Test("scenarios runnable on a bare host exclude exactly the ASP.NET one", () =>
{
    IReadOnlyList<string> bare = ScenarioCatalog.RunnableOn(HostCapabilities.None);
    Equal(ScenarioCatalog.All.Count - 1, bare.Count, "one scenario needs the ASP.NET shared framework");
    False(new List<string>(bare).Contains("aspnet-request-load"), "the Kestrel scenario cannot run on a host without ASP.NET");
});

Console.WriteLine();
Console.WriteLine("ResultConformance");
Test("a well-formed document is accepted", () =>
{
    ConformanceReport report = ResultConformance.Check(Document(Sample()));
    True(report.Ok, "a document built by the harness itself must conform: " + string.Join("; ", report.Errors));
});

Test("a latency result missing its method is rejected", () =>
{
    // Records without latencyMethod must be treated as not coordinated-omission-free, so a result
    // that carries percentiles has to say how they were obtained.
    RunResult result = Sample();
    result.LatencyMethod = null;
    False(ResultConformance.Check(Document(result)).Ok, "a latency result with no method must be rejected");
});

Test("a document naming an unknown scenario is rejected", () =>
{
    False(ResultConformance.Check(Document(Sample("not-a-scenario"))).Ok, "a scenario outside the catalogue must be rejected");
});

Test("a valid result that never confirmed its collector is rejected", () =>
{
    // "A run whose collector cannot be confirmed is invalid" is the brief's correctness criterion, so
    // the schema must not be able to express a confirmed-nothing valid run.
    RunResult result = Sample();
    result.CollectorConfirmed = false;
    False(ResultConformance.Check(Document(result)).Ok, "valid=true with collectorConfirmed=false is a contradiction");
});

Test("a valid result that did not finish is rejected", () =>
{
    RunResult result = Sample();
    result.Status = RunStatus.Timeout;
    False(ResultConformance.Check(Document(result)).Ok, "a timed-out run cannot also be valid");
});

Test("a negative throughput is rejected", () =>
{
    RunResult result = Sample();
    result.OperationsPerSecond = -1;
    False(ResultConformance.Check(Document(result)).Ok, "a negative rate is not a measurement");
});

Test("an open-loop result with no arrival rate is rejected", () =>
{
    RunResult result = Sample();
    result.ArrivalRatePerSecond = null;
    False(ResultConformance.Check(Document(result)).Ok, "an open-loop latency number is meaningless without the offered load");
});

Test("a declared skip explains itself through skipReason, an undeclared one does not", () =>
{
    // A skip is a declared non-run, not an invalid run, so its explanation lives in skipReason and
    // demanding invalidReason as well would only invite the uninformative invalidReason "skipped".
    // Both directions matter: the accept direction is what the corerun host's aspnet-request-load
    // row needs, and the reject direction is what stops a skip from being a silent absence.
    RunResult declared = Sample();
    declared.Status = RunStatus.Skipped;
    declared.Valid = false;
    declared.SkipReason = "host-lacks-aspnetcore-shared-framework";
    declared.InvalidReason = null;
    True(ResultConformance.Check(Document(declared)).Ok, "a skip with a skipReason must be accepted");

    RunResult undeclared = Sample();
    undeclared.Status = RunStatus.Skipped;
    undeclared.Valid = false;
    undeclared.SkipReason = null;
    undeclared.InvalidReason = null;
    False(ResultConformance.Check(Document(undeclared)).Ok, "a skip with no reason is a silent absence");
});

Test("a valid result with no runtime build identity is rejected", () =>
{
    // Section 5.2 of the brief: a number has to be tie-able to a commit later. A result that cannot
    // name the runtime it ran on is not re-checkable, so it does not conform.
    RunResult result = Sample();
    result.RuntimeBuildId = null;
    False(ResultConformance.Check(Document(result)).Ok, "a valid run must identify the runtime build it measured");
});

Test("conformance is checked against the written file, not the object model", () =>
{
    // Checking the in-memory object would attest to the object, not to the file anyone else reads.
    string path = Path.Combine(Path.GetTempPath(), $"lxr-results-{Guid.NewGuid():N}.json");
    try
    {
        ResultWriter.Write(path, Document(Sample()));
        ConformanceReport report = ResultConformance.CheckFile(path);
        True(report.Ok, "a written document must conform: " + string.Join("; ", report.Errors));

        File.WriteAllText(path, "{ \"schemaVersion\": 2, \"results\": [ { \"scenario\": \"nope\" } ] }");
        False(ResultConformance.CheckFile(path).Ok, "a hand-written malformed file must be rejected");

        File.WriteAllText(path, "{ not json at all");
        False(ResultConformance.CheckFile(path).Ok, "unparseable content must be rejected, not thrown past the caller");
    }
    finally
    {
        File.Delete(path);
    }
});

return Summarize();

static MatrixCell Cell(CollectorArm arm, int invocations, string? tag) => new()
{
    Scenario = "low-allocation-compute",
    Arm = arm,
    Host = HostDescriptor.Sdk("dotnet.exe", aspNetAvailable: false),
    Primary = PrimaryMetric.Throughput,
    Invocations = invocations,
    TimeoutSeconds = 60,
    Tag = tag,
};

static List<MatrixCell> TwoArmCells(int invocations) =>
[
    Cell(CollectorArms.Workstation, invocations, tag: null),
    Cell(CollectorArms.Server(8), invocations, tag: null),
];

static RunResult Sample(string scenario = "long-lived-cache") => new()
{
    Scenario = scenario,
    Collector = CollectorArms.WorkstationId,
    Host = "sdk",
    Status = RunStatus.Ok,
    Valid = true,
    CollectorConfirmed = true,
    OperationsPerSecond = 12345.6,
    LatencyMethod = OpenLoopDriver.LatencyMethod,
    ArrivalRatePerSecond = 1000,
    AchievedRatePerSecond = 999.7,
    LatencyP50Ms = 0.4,
    LatencyP99Ms = 1.2,
    LatencyP999Ms = 3.4,
    LatencyP9999Ms = 8.9,
    LatencyMaxMs = 12.0,
    Invocations = 3,
    Seed = 20040,
    WarmupSeconds = 5,
    SteadyStateSeconds = 20,
    RuntimeDescription = ".NET 11.0.0",
    RuntimeBuildId = "11.0.0+abcdef1234567890abcdef1234567890abcdef12",
    CoreClrSha256 = new string('a', 64),
    InducedCollections = 0,
};

static ResultDocument Document(RunResult result) => new()
{
    Id = "unit-test",
    Date = "2024-01-01",
    StepId = "P0.4",
    Results = [result],
};
