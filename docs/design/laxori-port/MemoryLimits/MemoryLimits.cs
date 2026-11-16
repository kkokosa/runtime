// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

// Usage: MemoryLimits <expected-reserve-MiB> <maximum-startup-private-MiB> [<live-MiB> <small|large> [oom]]
// A zero expectation skips that measurement's bound (Linux private bytes are not Windows commit charge).
static unsafe class MemoryLimits
{
    const ulong MiB = 1UL << 20;

    static void Check(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    static int Main(string[] args)
    {
        ulong expectedReserve = ulong.Parse(args[0]);
        ulong maximumPrivate = ulong.Parse(args[1]);
        int liveMiB = args.Length > 2 ? int.Parse(args[2]) : 0;
        string space = args.Length > 3 ? args[3] : "small";
        bool expectOom = args.Length > 4 && args[4] == "oom";
        Check(space == "small" || space == "large", "Unknown allocation space.");
        IntPtr library = NativeLibrary.Load(Environment.GetEnvironmentVariable("DOTNET_GCPath")!);
        var metric = (delegate* unmanaged[Cdecl]<uint, ulong>)NativeLibrary.GetExport(library, "GC_Laxori_GetMetric");
        GC.Collect();
        using Process process = Process.GetCurrentProcess();
        process.Refresh();
        ulong reserve = metric(35);
        ulong privateBytes = (ulong)process.PrivateMemorySize64;
        Console.WriteLine($"reserve_mib={reserve / MiB} hard_limit_mib={metric(44) / MiB} native_limit_mib={metric(45) / MiB} " +
            $"available_mib={(ulong)GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / MiB} " +
            $"private_mib={privateBytes / (double)MiB:F1} working_set_mib={process.WorkingSet64 / (double)MiB:F1}");
        Check(expectedReserve == 0 || reserve == expectedReserve * MiB, "Reservation does not match the expected limit.");
        Check(maximumPrivate == 0 || privateBytes <= maximumPrivate * MiB, "Startup commit charge scales with the reservation.");

        int bytes = space == "small" ? 16 * 1024 : 1024 * 1024;
        int count = checked((int)((long)liveMiB * (long)MiB / bytes));
        var retained = new List<byte[]>(count);
        try
        {
            for (int index = 0; index < count; index++)
            {
                byte[] array = new byte[bytes];
                for (int page = 0; page < bytes; page += 4096)
                    array[page] = (byte)(index + 1);
                retained.Add(array);
                if ((long)(index + 1) * bytes % (16 * (long)MiB) == 0)
                {
                    process.Refresh();
                    ulong logs = metric(59) + metric(60) + metric(61) + metric(62) +
                        metric(65) + metric(66) + metric(67) + metric(68);
                    Console.WriteLine($"live_mib={(long)(index + 1) * bytes / (long)MiB} " +
                        $"admitted_mib={metric(36) / MiB} native_planes_mib={metric(38) / MiB} " +
                        $"rc_logs_mib={logs / (double)MiB:F1} private_mib={process.PrivateMemorySize64 / (double)MiB:F1}");
                }
            }
            GC.Collect();
        }
        catch (OutOfMemoryException)
        {
            Console.WriteLine($"oom_after_arrays={retained.Count}");
            Check(expectOom, "Allocation failed below the expected limit.");
            GC.KeepAlive(retained);
            Console.WriteLine("PASS");
            return 0;
        }
        Check(!expectOom, "Allocation unexpectedly exceeded the configured reserve or hard limit.");
        for (int index = 0; index < retained.Count; index++)
            Check(retained[index][0] == (byte)(index + 1), "Live data changed after growth and collection.");
        Console.WriteLine($"live_mib={liveMiB} space={space} arrays={retained.Count} admitted_mib={metric(36) / MiB}");
        GC.KeepAlive(retained);
        Console.WriteLine("PASS");
        return 0;
    }
}
