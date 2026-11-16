# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

param(
    [Parameter(Mandatory)][int]$LimitMB,
    [Parameter(Mandatory)][string]$FilePath,
    [string]$Arguments = '',
    [switch]$ProcessLimit,
    # A suspended second process holds this commit to check whole-job accounting.
    [int]$CompanionCommitMB = 0
)
$ErrorActionPreference = 'Stop'
if ($LimitMB -le 0) { throw 'LimitMB must be positive.' }
if ($CompanionCommitMB -lt 0) { throw 'CompanionCommitMB must not be negative.' }
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class LaxoriJobTest
{
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimits
    {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo
    {
        public uint Size;
        public string Reserved, Desktop, Title;
        public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedBytes;
        public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimits limits, uint bytes);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr VirtualAllocEx(IntPtr process, IntPtr address, UIntPtr bytes, uint type, uint protection);
    static void Require(bool condition) { if (!condition) throw new Win32Exception(Marshal.GetLastWin32Error()); }

    public static int Run(string file, string arguments, ulong limit, bool processLimit, ulong companionCommit)
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        Require(job != IntPtr.Zero);
        ProcessInfo process = new ProcessInfo();
        ProcessInfo companion = new ProcessInfo();
        bool assigned = false;
        bool companionAssigned = false;
        try
        {
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000u | (processLimit ? 0x100u : 0x200u);
            if (processLimit) limits.ProcessMemory = (UIntPtr)limit;
            else limits.JobMemory = (UIntPtr)limit;
            Require(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))));
            StartupInfo startup = new StartupInfo();
            startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.Flags = 0x100;
            startup.Input = GetStdHandle(-10);
            startup.Output = GetStdHandle(-11);
            startup.Error = GetStdHandle(-12);
            Require(CreateProcess(file, new StringBuilder("\"" + file + "\" " + arguments), IntPtr.Zero,
                IntPtr.Zero, true, 4, IntPtr.Zero, null, ref startup, out process));
            Require(AssignProcessToJobObject(job, process.Process));
            assigned = true;
            if (companionCommit != 0)
            {
                Require(CreateProcess(file, new StringBuilder("\"" + file + "\""), IntPtr.Zero,
                    IntPtr.Zero, false, 4, IntPtr.Zero, null, ref startup, out companion));
                Require(AssignProcessToJobObject(job, companion.Process));
                companionAssigned = true;
                Require(VirtualAllocEx(companion.Process, IntPtr.Zero, (UIntPtr)companionCommit, 0x3000, 4) != IntPtr.Zero);
            }
            Require(ResumeThread(process.Thread) != uint.MaxValue);
            uint wait = WaitForSingleObject(process.Process, 600000);
            if (wait == 258) throw new TimeoutException("Job-limited workload exceeded ten minutes.");
            Require(wait == 0);
            uint code;
            Require(GetExitCodeProcess(process.Process, out code));
            return unchecked((int)code);
        }
        finally
        {
            if (process.Process != IntPtr.Zero && !assigned) TerminateProcess(process.Process, 1);
            if (companion.Process != IntPtr.Zero && !companionAssigned) TerminateProcess(companion.Process, 1);
            CloseHandle(job);
            if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
            if (process.Process != IntPtr.Zero) CloseHandle(process.Process);
            if (companion.Thread != IntPtr.Zero) CloseHandle(companion.Thread);
            if (companion.Process != IntPtr.Zero) CloseHandle(companion.Process);
        }
    }
}
'@
$file = (Resolve-Path $FilePath).Path
exit [LaxoriJobTest]::Run($file, $Arguments, [uint64]$LimitMB * 1048576, $ProcessLimit.IsPresent,
    [uint64]$CompanionCommitMB * 1048576)
