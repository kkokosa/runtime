// Start-up commit probe: after a GC.Collect, prints the private bytes (commit charge) and the working set of the process,
// and the largest committed private regions (VirtualQuery walk), so that a table that is sized by a reserve shows up.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

static class CommitProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct MEMORY_BASIC_INFORMATION
    {
        public UIntPtr BaseAddress, AllocationBase;
        public uint AllocationProtect, Alignment;
        public UIntPtr RegionSize;
        public uint State, Protect, Type;
    }

    [DllImport("kernel32.dll")]
    static extern UIntPtr VirtualQuery(UIntPtr address, out MEMORY_BASIC_INFORMATION info, UIntPtr length);

    static void Main(string[] args)
    {
        GC.Collect();
        Process p = Process.GetCurrentProcess();
        p.Refresh();
        Console.WriteLine($"private_mb={p.PrivateMemorySize64 / 1048576.0:F1} ws_mb={p.WorkingSet64 / 1048576.0:F1}");
        if (args.Length > 0 && args[0] == "regions")
        {
            var list = new List<(ulong Base, ulong Size)>();
            ulong address = 0;
            ulong total = 0;
            while (VirtualQuery((UIntPtr)address, out MEMORY_BASIC_INFORMATION mbi, (UIntPtr)Marshal.SizeOf<MEMORY_BASIC_INFORMATION>()) != UIntPtr.Zero)
            {
                ulong size = (ulong)mbi.RegionSize;
                if (mbi.State == 0x1000 && mbi.Type == 0x20000)
                {
                    total += size;
                    list.Add(((ulong)mbi.BaseAddress, size));
                }
                address = (ulong)mbi.BaseAddress + size;
                if (address >= 0x7FFFFFFE0000UL) break;
            }
            list.Sort((a, b) => b.Size.CompareTo(a.Size));
            Console.WriteLine($"committed private regions: {total / 1048576.0:F1} MB in {list.Count} regions");
            for (int i = 0; i < Math.Min(14, list.Count); i++)
            {
                Console.WriteLine($"  0x{list[i].Base:x} {list[i].Size / 1048576.0:F1} MB");
            }
        }
    }
}
