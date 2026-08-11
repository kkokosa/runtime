// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using Lxr.Harness.Core;
using Lxr.Harness.Runner;

int Fail(string message)
{
    Console.Error.WriteLine("lxr-harness runner: " + message);
    return 2;
}

RunnerOptions options;
try
{
    options = RunnerOptions.Parse(args);
}
catch (ArgumentException ex)
{
    return Fail(ex.Message);
}

string repoRoot = options.RepoRoot ?? FindRepoRoot(AppContext.BaseDirectory)
    ?? Directory.GetCurrentDirectory();
string buildRoot = options.BuildRoot ?? Path.Combine(repoRoot, "artifacts", "lxr-harness", "build", "bin");
string outputRoot = options.OutputRoot ?? Path.Combine(repoRoot, "artifacts", "lxr-harness", "runs");

List<HostDescriptor> discovered = HostDescriptor.Discover(repoRoot);

if (options.Command is "hosts")
{
    foreach (HostDescriptor host in discovered)
    {
        Console.WriteLine($"{host.Id,-10} aspnet={((host.Capabilities & HostCapabilities.AspNetCoreSharedFramework) != 0 ? "yes" : "no ")} {host.Executable}");
        Console.WriteLine($"           {host.Description}");
    }

    if (discovered.Count == 0)
    {
        Console.WriteLine($"No hosts found under '{repoRoot}'.");
    }

    return 0;
}

if (options.Command is "conformance")
{
    return RunConformance(options.ConformanceInput);
}

if (discovered.Count == 0)
{
    return Fail($"no usable host found under '{repoRoot}'. Expected .dotnet/dotnet.exe, artifacts/bin/testhost/*/dotnet.exe or artifacts/bin/coreclr/*/corerun.exe.");
}

var hosts = new List<HostDescriptor>();
if (options.Hosts.Count == 0)
{
    hosts.Add(discovered[0]);
}
else
{
    foreach (string id in options.Hosts)
    {
        HostDescriptor? match = discovered.Find(h => string.Equals(h.Id, id, StringComparison.OrdinalIgnoreCase));
        if (match is null)
        {
            return Fail($"host '{id}' was not discovered. Available: {string.Join(", ", discovered.ConvertAll(h => h.Id))}.");
        }

        hosts.Add(match);
    }
}

var arms = new List<CollectorArm>();
foreach (string id in options.Arms.Count > 0 ? options.Arms : [CollectorArms.WorkstationId, CollectorArms.ServerId])
{
    try
    {
        arms.Add(CollectorArms.Resolve(id, options.ServerHeapCount));
    }
    catch (ArgumentException ex)
    {
        return Fail(ex.Message);
    }
}

var scenarios = new List<string>();
foreach (string id in options.Scenarios.Count > 0 ? options.Scenarios : ScenarioCatalog.Ids)
{
    if (ScenarioCatalog.Find(id) is null)
    {
        return Fail($"unknown scenario '{id}'. Known: {string.Join(", ", ScenarioCatalog.Ids)}.");
    }

    scenarios.Add(id);
}

string runDirectory = Path.Combine(outputRoot, options.RunId);
Directory.CreateDirectory(runDirectory);

var runner = new MatrixRunner(options, repoRoot, buildRoot, runDirectory);

try
{
    if (options.Command is "controls")
    {
        var suite = new ControlSuite(options, runner, hosts[0]);
        List<ControlEvidence> evidence = suite.RunAll();

        string controlsPath = Path.Combine(runDirectory, "controls.json");
        ControlSuite.Write(controlsPath, evidence);
        string text = ControlSuite.Format(evidence);
        File.WriteAllText(Path.Combine(runDirectory, "controls.txt"), text);
        Console.WriteLine();
        Console.Write(text);

        int fired = 0;
        foreach (ControlEvidence control in evidence)
        {
            if (control.Fired)
            {
                fired++;
            }
        }

        Console.WriteLine($"{fired}/{evidence.Count} controls fired. Evidence: {controlsPath}");
        return fired == evidence.Count ? 0 : 1;
    }

    ResultDocument document = runner.Run(hosts, scenarios, arms);
    string resultsPath = Path.Combine(runDirectory, "results.json");
    ResultWriter.Write(resultsPath, document);

    ConformanceReport report = ResultConformance.Check(document);
    Console.WriteLine();
    Console.WriteLine(report.Format());
    Console.WriteLine($"Results: {resultsPath}");

    int valid = 0;
    int invalid = 0;
    int skippedCount = 0;
    foreach (RunResult result in document.Results)
    {
        if (result.Status == RunStatus.Skipped)
        {
            skippedCount++;
        }
        else if (result.Valid)
        {
            valid++;
        }
        else
        {
            invalid++;
        }
    }

    Console.WriteLine($"{valid} valid, {invalid} invalid, {skippedCount} declared skips.");
    return report.Ok && invalid == 0 ? 0 : 1;
}
finally
{
    // Leaving a mutated runtimeconfig.json behind would make the next manual run silently inherit the
    // last cell's collector.
    RuntimeConfigWriter.RestoreAll();
}

static string? FindRepoRoot(string start)
{
    var directory = new DirectoryInfo(start);
    while (directory is not null)
    {
        if (Directory.Exists(Path.Combine(directory.FullName, ".git")) ||
            File.Exists(Path.Combine(directory.FullName, ".git")))
        {
            return directory.FullName;
        }

        directory = directory.Parent;
    }

    return null;
}

static int RunConformance(string? input)
{
    // The conformance check needs its own negative test, or it is as control-less as anything else.
    ResultDocument good = SampleDocument(valid: true);
    ConformanceReport goodReport = ResultConformance.Check(good);

    ResultDocument bad = SampleDocument(valid: false);
    ConformanceReport badReport = ResultConformance.Check(bad);

    Console.WriteLine("conformance self-test");
    Console.WriteLine("  well-formed document: " + (goodReport.Ok ? "accepted" : "REJECTED - " + string.Join("; ", goodReport.Errors)));
    Console.WriteLine("  malformed document:   " + (badReport.Ok ? "ACCEPTED, which is a defect" : "rejected - " + string.Join("; ", badReport.Errors)));

    bool selfTestOk = goodReport.Ok && !badReport.Ok;
    if (input is null)
    {
        Console.WriteLine(selfTestOk ? "self-test passed" : "SELF-TEST FAILED");
        return selfTestOk ? 0 : 1;
    }

    if (!File.Exists(input))
    {
        Console.Error.WriteLine($"conformance: '{input}' does not exist.");
        return 2;
    }

    ConformanceReport fileReport = ResultConformance.CheckFile(input);
    Console.WriteLine();
    Console.WriteLine($"{input}:");
    Console.WriteLine(fileReport.Format());
    return selfTestOk && fileReport.Ok ? 0 : 1;
}

static ResultDocument SampleDocument(bool valid)
{
    var document = new ResultDocument
    {
        Id = "conformance-self-test",
        Date = "2022-11-01",
        StepId = "P0.4",
        Notes = "Synthetic record used only to prove the conformance check rejects what it should.",
    };

    var result = new RunResult
    {
        Scenario = valid ? "low-allocation-compute" : "not-a-scenario",
        Collector = valid ? CollectorArms.WorkstationId : "not-an-arm",
        Host = "sdk",
        OperationsPerSecond = valid ? 1000 : -1,
        Status = RunStatus.Ok,
        Valid = true,

        // The defect that must be caught: claiming validity without a confirmed collector is exactly
        // what "a run whose collector cannot be confirmed is invalid" forbids.
        CollectorConfirmed = valid,
        LatencyMethod = valid ? OpenLoopDriver.LatencyMethod : null,
        LatencyP99Ms = 1.0,
        ArrivalRatePerSecond = 1000,
        Invocations = valid ? 3 : 0,
        RuntimeBuildId = valid ? "0000000000000000000000000000000000000000" : null,
    };

    document.Results.Add(result);
    return document;
}
