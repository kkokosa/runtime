// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using Lxr.Harness.Core;

namespace Lxr.Harness.Runner;

/// <summary>All invocations of one cell, reduced to a result record.</summary>
public sealed class CellAggregate
{
    public required MatrixCell Cell { get; init; }

    public required List<InvocationOutcome> Outcomes { get; init; }

    public List<InvocationOutcome> ValidOutcomes { get; } = [];

    public double[] PrimarySamples { get; set; } = [];
}

/// <summary>
/// Turns invocations into result records and comparisons.
///
/// <para>The rule that shapes this type: <strong>a run whose collector cannot be confirmed is
/// invalid, and an invalid run cannot contribute to a ratio.</strong> Not "is flagged in the output" -
/// cannot contribute. A comparison containing an unconfirmed run is not published at all, because a
/// ratio silently computed over a run that used the wrong collector is worse than no ratio.</para>
/// </summary>
public static class Aggregator
{
    public const string CiMethodDescription = "percentile bootstrap over invocations, B=10000, seed=20040, 95%";

    public static CellAggregate Aggregate(MatrixCell cell, List<InvocationOutcome> outcomes)
    {
        var aggregate = new CellAggregate { Cell = cell, Outcomes = outcomes };
        var samples = new List<double>();

        foreach (InvocationOutcome outcome in outcomes)
        {
            if (!outcome.Valid || outcome.Report is not JsonElement report)
            {
                continue;
            }

            aggregate.ValidOutcomes.Add(outcome);
            if (TryReadPrimary(report, cell.Primary, out double value))
            {
                samples.Add(value);
            }
        }

        aggregate.PrimarySamples = [.. samples];
        return aggregate;
    }

    private static bool TryReadPrimary(JsonElement report, PrimaryMetric primary, out double value)
    {
        value = 0;
        if (!report.TryGetProperty("metrics", out JsonElement metrics))
        {
            return false;
        }

        string field = primary is PrimaryMetric.Latency ? "latencyP99Ms" : "operationsPerSecond";
        if (!metrics.TryGetProperty(field, out JsonElement element) || element.ValueKind != JsonValueKind.Number)
        {
            return false;
        }

        value = element.GetDouble();
        return true;
    }

    public static RunResult ToResult(CellAggregate aggregate, string runId, double noiseThresholdPercent)
    {
        MatrixCell cell = aggregate.Cell;
        var result = new RunResult
        {
            Scenario = cell.Scenario,
            Collector = cell.Arm.Id,
            Host = cell.Host.Id,
            HeapFactor = cell.HeapFactor,
            HeapLimitMb = cell.HeapLimitMb,
            Invocations = aggregate.ValidOutcomes.Count,
            Status = RunStatus.Ok,
        };

        foreach (KeyValuePair<string, string> property in cell.Arm.RuntimeProperties)
        {
            result.RequestedConfig[property.Key] = property.Value;
        }

        // Status is the worst thing that happened, not the best. A cell with any timeout or crash says
        // so, and the counts are kept in the notes so a partial failure is never rounded away.
        int timeouts = 0;
        int crashes = 0;
        int failures = 0;
        int markerless = 0;
        foreach (InvocationOutcome outcome in aggregate.Outcomes)
        {
            switch (outcome.Status)
            {
                case RunStatus.Timeout:
                    timeouts++;
                    break;
                case RunStatus.Crashed:
                    crashes++;
                    break;
                case RunStatus.Failed:
                    failures++;
                    break;
                default:
                    break;
            }

            if (!outcome.MarkerSeen)
            {
                markerless++;
            }
        }

        if (aggregate.ValidOutcomes.Count == 0)
        {
            result.Valid = false;
            result.CollectorConfirmed = false;
            result.Status = crashes > 0 ? RunStatus.Crashed
                : timeouts > 0 ? RunStatus.Timeout
                : RunStatus.Failed;
            result.InvalidReason = FirstInvalidReason(aggregate.Outcomes)
                ?? (crashes > 0 ? Core.InvalidReason.Crashed
                    : timeouts > 0 ? Core.InvalidReason.Timeout
                    : Core.InvalidReason.WorkerError);
            result.Notes = Describe(aggregate.Outcomes.Count, timeouts, crashes, failures, markerless);
            return result;
        }

        if (timeouts > 0 || crashes > 0 || failures > 0)
        {
            result.Status = RunStatus.Failed;
        }

        JsonElement report = aggregate.ValidOutcomes[^1].Report!.Value;
        result.CollectorConfirmed = true;
        result.Valid = true;

        PopulateFromReport(result, report, aggregate);

        double[] samples = aggregate.PrimarySamples;
        if (samples.Length > 0)
        {
            Array.Sort(samples);
            if (cell.Primary is PrimaryMetric.Latency)
            {
                result.LatencyP99Ms = Stats.Percentile(samples, 50);
            }
            else
            {
                result.OperationsPerSecond = Stats.Mean(samples);
            }
        }

        double background = 0;
        int backgroundCount = 0;
        foreach (InvocationOutcome outcome in aggregate.ValidOutcomes)
        {
            if (outcome.BackgroundLoadPercent is double load)
            {
                background += load;
                backgroundCount++;
            }
        }

        if (backgroundCount > 0)
        {
            result.BackgroundLoadPercent = background / backgroundCount;
            result.Noisy = result.BackgroundLoadPercent > noiseThresholdPercent;
        }

        result.Notes = Describe(aggregate.Outcomes.Count, timeouts, crashes, failures, markerless) +
            $" runId={runId}";
        return result;
    }

    private static string? FirstInvalidReason(List<InvocationOutcome> outcomes)
    {
        foreach (InvocationOutcome outcome in outcomes)
        {
            if (outcome.Status is RunStatus.Timeout)
            {
                return Core.InvalidReason.Timeout;
            }

            if (outcome.Status is RunStatus.Crashed)
            {
                return Core.InvalidReason.Crashed;
            }

            if (outcome.Report is JsonElement report &&
                report.TryGetProperty("invalidReason", out JsonElement reason) &&
                reason.ValueKind is JsonValueKind.String)
            {
                return reason.GetString();
            }

            if (!outcome.MarkerSeen)
            {
                return Core.InvalidReason.MarkerMissing;
            }
        }

        return null;
    }

    private static void PopulateFromReport(RunResult result, JsonElement report, CellAggregate aggregate)
    {
        if (report.TryGetProperty("metrics", out JsonElement metrics))
        {
            result.OperationsPerSecond = ReadDouble(metrics, "operationsPerSecond") ?? 0;
            result.LatencyP50Ms = ReadDouble(metrics, "latencyP50Ms");
            result.LatencyP99Ms = ReadDouble(metrics, "latencyP99Ms");
            result.LatencyP999Ms = ReadDouble(metrics, "latencyP999Ms");
            result.LatencyP9999Ms = ReadDouble(metrics, "latencyP9999Ms");
            result.LatencyMaxMs = ReadDouble(metrics, "latencyMaxMs");
            result.ServiceTimeP99Ms = ReadDouble(metrics, "serviceTimeP99Ms");
            result.ArrivalRatePerSecond = ReadDouble(metrics, "arrivalRatePerSecond");
            result.AchievedRatePerSecond = ReadDouble(metrics, "achievedRatePerSecond");
            result.LatencyMethod = ReadString(metrics, "latencyMethod");
            result.Overloaded = metrics.TryGetProperty("overloaded", out JsonElement overloaded) &&
                overloaded.ValueKind is JsonValueKind.True;
        }

        if (report.TryGetProperty("gc", out JsonElement gc))
        {
            result.PauseAverageMs = ReadDouble(gc, "pauseAverageMs") ?? 0;
            result.PauseP99Ms = ReadDouble(gc, "pauseP99Ms") ?? 0;
            result.PauseMaxMs = ReadDouble(gc, "pauseMaxMs") ?? 0;
            result.InducedCollections = (int)(ReadDouble(gc, "inducedCollections") ?? 0);
            result.Gen0Collections = (int)(ReadDouble(gc, "gen0Collections") ?? 0);
            result.Gen1Collections = (int)(ReadDouble(gc, "gen1Collections") ?? 0);
            result.Gen2Collections = (int)(ReadDouble(gc, "gen2Collections") ?? 0);
            result.PauseSource = ReadString(gc, "pauseSource");
        }

        if (report.TryGetProperty("process", out JsonElement process))
        {
            result.WorkingSetMb = ReadDouble(process, "workingSetMb") ?? 0;
            result.CommittedMb = ReadDouble(process, "committedMb") ?? 0;
        }

        if (report.TryGetProperty("runtime", out JsonElement runtime))
        {
            result.RuntimeDescription = ReadString(runtime, "frameworkDescription");
            result.CoreClrSha256 = ReadString(runtime, "coreClrSha256");
            result.RuntimeBuildId = ReadString(runtime, "commitSha") is string sha && sha.Length > 0
                ? sha
                : ReadString(runtime, "coreClrSha256");
        }

        if (report.TryGetProperty("observedGcConfig", out JsonElement observed) &&
            observed.ValueKind is JsonValueKind.Object)
        {
            foreach (JsonProperty property in observed.EnumerateObject())
            {
                result.ObservedConfig[property.Name] = property.Value.ToString();
            }
        }

        if (report.TryGetProperty("knobs", out JsonElement knobs) && knobs.ValueKind is JsonValueKind.Array)
        {
            foreach (JsonElement knob in knobs.EnumerateArray())
            {
                string? name = ReadString(knob, "name");
                string? evidence = ReadString(knob, "evidence");
                if (name is not null && evidence is not null)
                {
                    result.ConfigEvidence[name] = evidence;
                }
            }
        }

        if (report.TryGetProperty("unverifiedKnobs", out JsonElement unverified) &&
            unverified.ValueKind is JsonValueKind.Array)
        {
            foreach (JsonElement knob in unverified.EnumerateArray())
            {
                if (knob.GetString() is string text)
                {
                    result.UnverifiedKnobs.Add(text);
                }
            }
        }

        result.Seed = (long)(ReadDouble(report, "seed") ?? 0);
        result.WarmupSeconds = ReadDouble(report, "warmupSeconds") ?? 0;
        result.SteadyStateSeconds = ReadDouble(report, "steadyStateSeconds") ?? 0;
        result.RawSamplesPath = ReadString(report, "samplesPath");
    }

    /// <summary>
    /// Computes the ratio of a candidate arm to a baseline arm, or refuses.
    ///
    /// <para>Refusal is the point. If either side contains a run whose collector was not confirmed,
    /// or has too few valid invocations to bootstrap, no ratio is produced and the reason is recorded.
    /// The brief's requirement that "a run whose collector cannot be confirmed is invalid" is only
    /// meaningful if invalidity actually prevents a number from being published.</para>
    /// </summary>
    public static (RatioEstimate? Estimate, string? Refusal) Ratio(CellAggregate baseline, CellAggregate candidate)
    {
        if (baseline.Outcomes.Count != baseline.ValidOutcomes.Count)
        {
            return (null, $"baseline cell {baseline.Cell.Id} has {baseline.Outcomes.Count - baseline.ValidOutcomes.Count} invalid invocation(s)");
        }

        if (candidate.Outcomes.Count != candidate.ValidOutcomes.Count)
        {
            return (null, $"candidate cell {candidate.Cell.Id} has {candidate.Outcomes.Count - candidate.ValidOutcomes.Count} invalid invocation(s)");
        }

        if (baseline.PrimarySamples.Length == 0 || candidate.PrimarySamples.Length == 0)
        {
            return (null, "one or both cells produced no primary samples");
        }

        return (Stats.BootstrapRatio(baseline.PrimarySamples, candidate.PrimarySamples), null);
    }

    private static double? ReadDouble(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind is JsonValueKind.Number
            ? value.GetDouble()
            : null;

    private static string? ReadString(JsonElement element, string name) =>
        element.TryGetProperty(name, out JsonElement value) && value.ValueKind is JsonValueKind.String
            ? value.GetString()
            : null;

    private static string Describe(int total, int timeouts, int crashes, int failures, int markerless)
    {
        var parts = new List<string> { $"invocations={total.ToString(CultureInfo.InvariantCulture)}" };
        if (timeouts > 0)
        {
            parts.Add($"timeouts={timeouts}");
        }

        if (crashes > 0)
        {
            parts.Add($"crashes={crashes}");
        }

        if (failures > 0)
        {
            parts.Add($"failed={failures}");
        }

        if (markerless > 0)
        {
            parts.Add($"markerMissing={markerless}");
        }

        return string.Join(", ", parts);
    }
}
