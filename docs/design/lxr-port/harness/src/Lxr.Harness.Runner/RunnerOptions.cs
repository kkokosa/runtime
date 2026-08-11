// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Lxr.Harness.Core;

namespace Lxr.Harness.Runner;

/// <summary>Command line for the orchestrator.</summary>
public sealed class RunnerOptions
{
    public string Command { get; private set; } = "matrix";

    public string? RepoRoot { get; private set; }

    public string? BuildRoot { get; private set; }

    public string? OutputRoot { get; private set; }

    public List<string> Scenarios { get; } = [];

    public List<string> Arms { get; } = [];

    public List<string> Hosts { get; } = [];

    public List<double> HeapFactors { get; } = [];

    public int Invocations { get; private set; } = 3;

    public int Seed { get; private set; } = 20221101;

    public int ServerHeapCount { get; private set; } = 8;

    public double WarmupSeconds { get; private set; } = 1.0;

    public double SteadyStateSeconds { get; private set; } = 3.0;

    public int Workers { get; private set; } = 2;

    public string Mode { get; private set; } = "throughput";

    public double ArrivalRatePerSecond { get; private set; } = 1000;

    public long DumpBudgetMb { get; private set; } = 512;

    public int TimeoutMultiplierPercent { get; private set; } = 100;

    public double NoiseThresholdPercent { get; private set; } = 70;

    public string? BaselineArm { get; private set; }

    public string RunId { get; private set; } = "smoke-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);

    public string? ConformanceInput { get; private set; }

    public string? Control { get; private set; }

    public bool KeepSamples { get; private set; } = true;

    public static RunnerOptions Parse(string[] args)
    {
        var options = new RunnerOptions();
        for (int i = 0; i < args.Length; i++)
        {
            string arg = args[i];
            switch (arg)
            {
                case "matrix" or "controls" or "conformance" or "hosts":
                    options.Command = arg;
                    break;
                case "--repo-root":
                    options.RepoRoot = Next(args, ref i);
                    break;
                case "--build-root":
                    options.BuildRoot = Next(args, ref i);
                    break;
                case "--output":
                    options.OutputRoot = Next(args, ref i);
                    break;
                case "--scenario":
                    options.Scenarios.AddRange(Next(args, ref i).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                    break;
                case "--arm":
                    options.Arms.AddRange(Next(args, ref i).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                    break;
                case "--host":
                    options.Hosts.AddRange(Next(args, ref i).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                    break;
                case "--heap-factor":
                    foreach (string factor in Next(args, ref i).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                    {
                        options.HeapFactors.Add(double.Parse(factor, CultureInfo.InvariantCulture));
                    }

                    break;
                case "--invocations":
                    options.Invocations = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--seed":
                    options.Seed = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--server-heap-count":
                    options.ServerHeapCount = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--warmup-seconds":
                    options.WarmupSeconds = double.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--duration-seconds":
                    options.SteadyStateSeconds = double.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--workers":
                    options.Workers = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--mode":
                    options.Mode = Next(args, ref i);
                    break;
                case "--rate":
                    options.ArrivalRatePerSecond = double.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--dump-budget-mb":
                    options.DumpBudgetMb = long.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--timeout-multiplier-percent":
                    options.TimeoutMultiplierPercent = int.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--noise-threshold-percent":
                    options.NoiseThresholdPercent = double.Parse(Next(args, ref i), CultureInfo.InvariantCulture);
                    break;
                case "--baseline-arm":
                    options.BaselineArm = Next(args, ref i);
                    break;
                case "--run-id":
                    options.RunId = Next(args, ref i);
                    break;
                case "--input":
                    options.ConformanceInput = Next(args, ref i);
                    break;
                case "--control":
                    options.Control = Next(args, ref i);
                    break;
                case "--no-samples":
                    options.KeepSamples = false;
                    break;
                default:
                    throw new ArgumentException($"Unrecognised argument '{arg}'.");
            }
        }

        return options;
    }

    private static string Next(string[] args, ref int index)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"Argument '{args[index]}' requires a value.");
        }

        return args[++index];
    }

    public int TimeoutFor(int baseSeconds) =>
        Math.Max(5, (int)(baseSeconds * (TimeoutMultiplierPercent / 100.0)));
}
