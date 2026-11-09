// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Memory-call micro benchmark for the Windows-versus-Linux comparison of Laxori (the cost behind the large-object space and the
// block commit paths). Each thread repeats: give the pages back, take them again, write one byte in every 4 KiB page.
//   mode "recommit": Windows VirtualFree(MEM_DECOMMIT) + VirtualAlloc(MEM_COMMIT)   Linux munmap-free equivalent: mprotect(NONE) + madvise(DONTNEED) + mprotect(RW)
//   mode "discard":  Windows DiscardVirtualMemory (the pages stay committed)       Linux madvise(MADV_DONTNEED) only (what Laxori does on Unix)
//   mode "touch":    first touch of fresh committed pages (the page fault cost): Windows VirtualAlloc(MEM_COMMIT) of new pages, Linux mmap
// usage: commitbench <mode> <threads> <MiB per call> <calls per thread>
// Prints: total wall ms, ns per call and ns per 4 KiB page touched.
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#endif

static const size_t Page = 4096;

static void Touch(uint8_t* p, size_t bytes)
{
    for (size_t i = 0; i < bytes; i += Page)
    {
        p[i] = 1;
    }
}

int main(int argc, char** argv)
{
    if (argc < 5)
    {
        return 2;
    }
    std::string mode = argv[1];
    int threads = atoi(argv[2]);
    size_t bytes = static_cast<size_t>(atof(argv[3]) * 1024 * 1024);
    int calls = atoi(argv[4]);
    std::vector<std::thread> workers;
    auto start = std::chrono::steady_clock::now();
    for (int t = 0; t < threads; t++)
    {
        workers.emplace_back([&]()
        {
#ifdef _WIN32
            uint8_t* area = static_cast<uint8_t*>(VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
#else
            uint8_t* area = static_cast<uint8_t*>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0));
#endif
            if (area == nullptr)
            {
                std::abort();
            }
            Touch(area, bytes);
            for (int i = 0; i < calls; i++)
            {
                if (mode == "recommit")
                {
#ifdef _WIN32
                    VirtualFree(area, bytes, MEM_DECOMMIT);
                    VirtualAlloc(area, bytes, MEM_COMMIT, PAGE_READWRITE);
#else
                    mprotect(area, bytes, PROT_NONE);
                    madvise(area, bytes, MADV_DONTNEED);
                    mprotect(area, bytes, PROT_READ | PROT_WRITE);
#endif
                    Touch(area, bytes);
                }
                else if (mode == "discard")
                {
#ifdef _WIN32
                    DiscardVirtualMemory(area, bytes);
#else
                    madvise(area, bytes, MADV_DONTNEED);
#endif
                    Touch(area, bytes);
                }
                else
                {
                    // fresh pages every call
#ifdef _WIN32
                    uint8_t* fresh = static_cast<uint8_t*>(VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
                    Touch(fresh, bytes);
                    VirtualFree(fresh, 0, MEM_RELEASE);
#else
                    uint8_t* fresh = static_cast<uint8_t*>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0));
                    Touch(fresh, bytes);
                    munmap(fresh, bytes);
#endif
                }
            }
        });
    }
    for (auto& w : workers)
    {
        w.join();
    }
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    double totalCalls = static_cast<double>(threads) * calls;
    std::printf("%s threads=%d MiB=%.2f calls=%d wall_ms=%.1f ns_per_call=%.0f ns_per_page=%.0f\n", mode.c_str(), threads,
        static_cast<double>(bytes) / (1024 * 1024), calls, ms, ms * 1e6 / totalCalls * threads,
        ms * 1e6 / totalCalls * threads / (static_cast<double>(bytes) / Page));
    return 0;
}
