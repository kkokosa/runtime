// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc/env/common.h"
#include "../../../../src/coreclr/gc/env/gcenv.h"
#include "../../../../src/coreclr/gc_laxori/laxori_large_object_space.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

#ifdef _WIN32
// Windows has no setenv/unsetenv. The engine reads these variables with getenv, which sees _putenv_s.
static int setenv(const char* name, const char* value, int) { return _putenv_s(name, value); }
static int unsetenv(const char* name) { return _putenv_s(name, ""); }
#endif
void LaxoriTestFailCommitAfter(int64_t calls);
void LaxoriTestFailDecommitAfter(int64_t calls);

namespace
{
    int s_checks;
    int s_failures;

    void Check(bool condition, const char* name)
    {
        s_checks++;
        if (!condition)
        {
            s_failures++;
            std::printf("FAIL: %s\n", name);
        }
    }

    uintptr_t Load(
        SideMetadataManager& metadata,
        LaxoriSideMetadataKind kind,
        uintptr_t address)
    {
        uintptr_t value = UINTPTR_MAX;
        Check(
            metadata.Load(
                kind,
                address,
                SideMetadataMemoryOrder::SequentiallyConsistent,
                &value) == SideMetadataResult::Success,
            "metadata load");
        return value;
    }

    constexpr size_t Page = LaxoriLargeObjectSpace::PageBytes;
    constexpr size_t StructureBytes = 16 * 1024 * 1024;
    constexpr size_t StructurePages = StructureBytes / Page;

    // The allocations that are alive, the structure of the space, and the pages that are free must agree.
    void CheckStructure(
        const LaxoriLargeObjectSpace& space, const std::vector<LaxoriLargeObjectAllocation>& live, const char* name)
    {
        size_t activePages = 0;
        for (const LaxoriLargeObjectAllocation& allocation : live)
        {
            activePages += allocation.page_count;
        }
        size_t active = SIZE_MAX;
        size_t freePages = SIZE_MAX;
        Check(space.ValidateStructure(&active, &freePages) == LaxoriLargeObjectResult::Success, name);
        Check(active == live.size(), "structure active count");
        Check(freePages == StructurePages - activePages, "structure free pages");
    }

    bool Overlap(const LaxoriLargeObjectAllocation& left, const LaxoriLargeObjectAllocation& right)
    {
        return left.page_start < right.page_start + right.page_count * Page &&
            right.page_start < left.page_start + left.page_count * Page;
    }

    void CheckLookups(const LaxoriLargeObjectSpace& space, const LaxoriLargeObjectAllocation& expected)
    {
        LaxoriLargeObjectAllocation found;
        Check(
            space.GetAllocation(expected.object, &found) == LaxoriLargeObjectResult::Success &&
                found.object == expected.object && found.page_start == expected.page_start &&
                found.object_bytes == expected.object_bytes && found.page_count == expected.page_count &&
                found.padding_bytes == expected.padding_bytes && found.owner == expected.owner,
            "lookup by object");
        Check(
            space.GetAllocation(expected.object + 8, &found) == LaxoriLargeObjectResult::NotFound,
            "lookup by interior address is not an object lookup");
        Check(
            space.GetContainingAllocation(expected.object, &found) == LaxoriLargeObjectResult::Success &&
                found.object == expected.object,
            "containing lookup of the first byte");
        Check(
            space.GetContainingAllocation(expected.object + expected.object_bytes - 1, &found) ==
                    LaxoriLargeObjectResult::Success &&
                found.object == expected.object && found.owner == expected.owner,
            "containing lookup of the last byte");
        Check(
            space.GetContainingAllocation(expected.object + expected.object_bytes / 2, &found) ==
                    LaxoriLargeObjectResult::Success &&
                found.object == expected.object,
            "containing lookup of the middle");
        if (expected.padding_bytes != 0)
        {
            Check(
                space.GetContainingAllocation(expected.page_start, &found) == LaxoriLargeObjectResult::NotFound,
                "containing lookup of the padding");
            Check(
                space.GetAllocation(expected.page_start, &found) == LaxoriLargeObjectResult::NotFound,
                "lookup of the page start before the object");
        }
        uintptr_t end = expected.object + expected.object_bytes;
        if (end < expected.page_start + expected.page_count * Page)
        {
            Check(
                space.GetContainingAllocation(end, &found) == LaxoriLargeObjectResult::NotFound,
                "containing lookup of the slack after the object");
        }
    }

    // A small deterministic generator, so a failure repeats.
    struct Random
    {
        uint64_t state;
        uint32_t Next()
        {
            state = state * 6364136223846793005ull + 1442695040888963407ull;
            return static_cast<uint32_t>(state >> 33);
        }
    };

    void RunLookupChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "lookup space");
        uintptr_t start = space.GetReservationStart();
        std::vector<LaxoriLargeObjectAllocation> live;
        const size_t sizes[] = {40000, 100000, 32768, 65536, 32769};
        for (size_t size : sizes)
        {
            LaxoriLargeObjectAllocation allocation;
            Check(space.Allocate(size, 8, 0, Owner, &allocation) == LaxoriLargeObjectResult::Success, "lookup allocate");
            live.push_back(allocation);
        }
        // An allocation with padding in front of the object: the object starts after the first bytes of its first page.
        LaxoriLargeObjectAllocation padded;
        Check(
            space.Allocate(50000, 64, 8, Owner + 1, &padded) == LaxoriLargeObjectResult::Success &&
                padded.padding_bytes != 0 && ((padded.object + 8) & 63) == 0,
            "lookup padded allocate");
        live.push_back(padded);
        for (const LaxoriLargeObjectAllocation& allocation : live)
        {
            CheckLookups(space, allocation);
        }
        CheckStructure(space, live, "lookup structure");

        LaxoriLargeObjectAllocation found;
        Check(space.GetAllocation(start - 8, &found) == LaxoriLargeObjectResult::NotFound, "lookup below the reservation");
        Check(space.GetAllocation(start + StructureBytes, &found) == LaxoriLargeObjectResult::NotFound, "lookup above the reservation");
        Check(space.GetContainingAllocation(UINTPTR_MAX, &found) == LaxoriLargeObjectResult::NotFound, "containing lookup of the top");
        Check(space.GetContainingAllocation(0, &found) == LaxoriLargeObjectResult::NotFound, "containing lookup of zero");
        const LaxoriLargeObjectAllocation& last = live.back();
        Check(
            space.GetContainingAllocation(last.page_start + last.page_count * Page + 16, &found) ==
                LaxoriLargeObjectResult::NotFound,
            "containing lookup of a free page");

        // The lookups of a released allocation fail, and the neighbours stay.
        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "lookup begin release");
        LaxoriLargeObjectAllocation victim = live[1];
        Check(space.TryRelease(victim.object, Owner) == LaxoriLargeObjectResult::Success, "lookup release");
        Check(space.TryRelease(victim.object, Owner) == LaxoriLargeObjectResult::NotFound, "double release");
        Check(space.GetAllocation(victim.object, &found) == LaxoriLargeObjectResult::NotFound, "lookup after release");
        Check(
            space.GetContainingAllocation(victim.object + 8, &found) == LaxoriLargeObjectResult::NotFound,
            "containing lookup after release");
        live.erase(live.begin() + 1);
        for (const LaxoriLargeObjectAllocation& allocation : live)
        {
            CheckLookups(space, allocation);
        }
        bool updated;
        Check(
            space.TryMarkAndPromote(victim.object, Owner, &updated) == LaxoriLargeObjectResult::NotFound,
            "promote after release");
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "lookup end release");
        CheckStructure(space, live, "lookup structure after release");
        space.Shutdown();
        Check(space.GetAllocation(live[0].object, &found) == LaxoriLargeObjectResult::NotInitialized, "lookup after shutdown");
    }

    // The first fit by address, the remainder of a free span, and the merge of free neighbours.
    void RunFreeSpanChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "free span space");
        uintptr_t start = space.GetReservationStart();
        std::vector<LaxoriLargeObjectAllocation> live;
        // The pages of the objects: a 10, b 25, c 8, d 16, e 8, f 8.
        const size_t sizes[] = {40000, 100000, 32768, 65536, 32768, 32768};
        LaxoriLargeObjectAllocation objects[6];
        for (size_t index = 0; index < 6; index++)
        {
            Check(
                space.Allocate(sizes[index], 8, 0, Owner, &objects[index]) == LaxoriLargeObjectResult::Success,
                "free span allocate");
            Check(
                objects[index].page_start == (index == 0 ? start : objects[index - 1].page_start +
                    objects[index - 1].page_count * Page),
                "allocation takes the lowest address");
            live.push_back(objects[index]);
        }
        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "free span begin release");
        Check(space.TryRelease(objects[1].object, Owner) == LaxoriLargeObjectResult::Success, "release b");
        Check(space.TryRelease(objects[3].object, Owner) == LaxoriLargeObjectResult::Success, "release d");
        live.erase(live.begin() + 3);
        live.erase(live.begin() + 1);
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "free span end release");
        CheckStructure(space, live, "two holes");

        // The first fit by address takes the hole of b (25 pages) for 16 pages, and not the exact hole of d.
        LaxoriLargeObjectAllocation fromB;
        Check(space.Allocate(65536, 8, 0, Owner, &fromB) == LaxoriLargeObjectResult::Success, "first fit allocate");
        Check(fromB.page_start == objects[1].page_start, "first fit takes the lowest hole that fits");
        live.push_back(fromB);
        // The remainder of the hole of b is 9 pages, and the next 8 pages start right after fromB.
        LaxoriLargeObjectAllocation remainder;
        Check(space.Allocate(32768, 8, 0, Owner, &remainder) == LaxoriLargeObjectResult::Success, "remainder allocate");
        Check(remainder.page_start == fromB.page_start + fromB.page_count * Page, "remainder start");
        live.push_back(remainder);
        // One page is left in the hole of b, so 16 pages go to the hole of d.
        LaxoriLargeObjectAllocation fromD;
        Check(space.Allocate(65536, 8, 0, Owner, &fromD) == LaxoriLargeObjectResult::Success, "second hole allocate");
        Check(fromD.page_start == objects[3].page_start, "second hole start");
        live.push_back(fromD);
        CheckStructure(space, live, "after the holes are used");
        // A request that no hole fits goes after the last object.
        LaxoriLargeObjectAllocation tail;
        Check(space.Allocate(200000, 8, 0, Owner, &tail) == LaxoriLargeObjectResult::Success, "tail allocate");
        Check(tail.page_start == objects[5].page_start + objects[5].page_count * Page, "tail start");
        live.push_back(tail);
        CheckStructure(space, live, "after the tail allocation");

        // Whatever the order of the releases, all free neighbours merge into one span.
        for (int order = 0; order < 4; order++)
        {
            std::vector<LaxoriLargeObjectAllocation> victims = live;
            if (order == 1)
            {
                std::reverse(victims.begin(), victims.end());
            }
            else if (order == 2)
            {
                std::vector<LaxoriLargeObjectAllocation> interleaved;
                for (size_t index = 0; index < victims.size(); index += 2)
                {
                    interleaved.push_back(victims[index]);
                }
                for (size_t index = 1; index < victims.size(); index += 2)
                {
                    interleaved.push_back(victims[index]);
                }
                victims = interleaved;
            }
            else if (order == 3)
            {
                Random random{77};
                for (size_t index = victims.size(); index > 1; index--)
                {
                    std::swap(victims[index - 1], victims[random.Next() % index]);
                }
            }
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "merge begin release");
            for (const LaxoriLargeObjectAllocation& victim : victims)
            {
                Check(space.TryRelease(victim.object, Owner) == LaxoriLargeObjectResult::Success, "merge release");
            }
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "merge end release");
            CheckStructure(space, std::vector<LaxoriLargeObjectAllocation>(), "all released");
            LaxoriLargeObjectAllocation whole;
            Check(
                space.Allocate(StructureBytes, 8, 0, Owner, &whole) == LaxoriLargeObjectResult::Success &&
                    whole.page_start == start && whole.page_count == StructurePages,
                "released neighbours merge into one span");
            Check(space.Allocate(32768, 8, 0, Owner, &whole) == LaxoriLargeObjectResult::OutOfMemory, "no space left");
            LaxoriLargeObjectAllocation again;
            Check(space.GetAllocation(start, &again) == LaxoriLargeObjectResult::Success, "whole lookup");
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "whole begin release");
            Check(space.TryRelease(start, Owner) == LaxoriLargeObjectResult::Success, "whole release");
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "whole end release");
            // Put the objects back for the next order.
            for (LaxoriLargeObjectAllocation& object : live)
            {
                Check(space.Allocate(object.object_bytes, 8, 0, Owner, &object) == LaxoriLargeObjectResult::Success, "refill");
            }
            CheckStructure(space, live, "refilled");
        }
        space.Shutdown();
    }

    // Random allocations and releases against a model of the pages.
    void RunRandomChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "random space");
        Random random{12345};
        std::vector<LaxoriLargeObjectAllocation> live;
        size_t failures = 0;
        for (int round = 0; round < 300; round++)
        {
            size_t allocations = random.Next() % 9;
            for (size_t index = 0; index < allocations; index++)
            {
                size_t bytes = 32768 + (random.Next() % 20 == 0 ? random.Next() % 1500000 : random.Next() % 120000);
                LaxoriLargeObjectAllocation allocation;
                LaxoriLargeObjectResult result = space.Allocate(bytes, 8, 0, Owner, &allocation);
                if (result == LaxoriLargeObjectResult::Success)
                {
                    for (const LaxoriLargeObjectAllocation& other : live)
                    {
                        Check(!Overlap(allocation, other), "random allocations do not overlap");
                    }
                    live.push_back(allocation);
                }
                else
                {
                    Check(result == LaxoriLargeObjectResult::OutOfMemory, "random failure is out of memory");
                    failures++;
                }
            }
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "random begin release");
            size_t releases = live.empty() ? 0 : random.Next() % (live.size() + 1);
            for (size_t index = 0; index < releases; index++)
            {
                size_t victim = random.Next() % live.size();
                Check(space.TryRelease(live[victim].object, Owner) == LaxoriLargeObjectResult::Success, "random release");
                live.erase(live.begin() + victim);
            }
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "random end release");
            if (round % 10 == 0)
            {
                CheckStructure(space, live, "random structure");
                for (const LaxoriLargeObjectAllocation& allocation : live)
                {
                    CheckLookups(space, allocation);
                }
            }
        }
        CheckStructure(space, live, "random final structure");
        // Fill the rest of the space, which is fragmented now, until a request fails.
        bool exhausted = false;
        for (int index = 0; index < 400 && !exhausted; index++)
        {
            LaxoriLargeObjectAllocation allocation;
            LaxoriLargeObjectResult result = space.Allocate(100000, 8, 0, Owner, &allocation);
            if (result == LaxoriLargeObjectResult::Success)
            {
                live.push_back(allocation);
            }
            else
            {
                exhausted = result == LaxoriLargeObjectResult::OutOfMemory;
                Check(exhausted, "fill failure is out of memory");
                break;
            }
        }
        Check(exhausted, "the random run fills the space");
        CheckStructure(space, live, "random full structure");
        space.Shutdown();
    }

    // Failures of the commit and of the decommit leave the space as it was.
    void RunFailureChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "failure space");
        std::vector<LaxoriLargeObjectAllocation> live;
        LaxoriLargeObjectAllocation first;
        Check(space.Allocate(40000, 8, 0, Owner, &first) == LaxoriLargeObjectResult::Success, "failure first");
        live.push_back(first);

        LaxoriLargeObjectAllocation second;
#if !defined(HOST_UNIX) || defined(LAXORI_LOS_PORTABLE_COMMIT)
        // The Unix space commits the admitted range once, and the other platforms commit the pages of each allocation.
        LaxoriTestFailCommitAfter(0);
        LaxoriLargeObjectAllocation failed;
        Check(space.Allocate(100000, 8, 0, Owner, &failed) == LaxoriLargeObjectResult::CommitFailed, "commit failure");
        LaxoriTestFailCommitAfter(-1);
        CheckStructure(space, live, "structure after commit failure");
        Check(space.GetCommittedBytes() == first.page_count * Page, "committed bytes after commit failure");
#endif
        Check(space.Allocate(100000, 8, 0, Owner, &second) == LaxoriLargeObjectResult::Success, "allocate after commit failure");
        Check(second.page_start == first.page_start + first.page_count * Page, "pages of the failed commit are reused");
        live.push_back(second);

        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "failure begin release");
        LaxoriTestFailDecommitAfter(0);
        Check(space.TryRelease(first.object, Owner) == LaxoriLargeObjectResult::DecommitFailed, "decommit failure");
        LaxoriTestFailDecommitAfter(-1);
        LaxoriLargeObjectAllocation found;
        Check(
            space.GetAllocation(first.object, &found) == LaxoriLargeObjectResult::Success && found.owner == Owner,
            "allocation stays after decommit failure");
        CheckStructure(space, live, "structure after decommit failure");
        size_t matureBytes;
        size_t slack;
        Check(space.GetMatureStatistics(&matureBytes, &slack) == LaxoriLargeObjectResult::Success, "statistics after decommit failure");
        Check(space.TryRelease(first.object, Owner) == LaxoriLargeObjectResult::Success, "release after decommit failure");
        live.erase(live.begin());
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "failure end release");
        CheckStructure(space, live, "structure after the release");
        Check(space.GetCommittedBytes() == second.page_count * Page, "committed bytes after the release");
        space.Shutdown();
    }

    // The space grows in a quiescent state, and the new pages merge with the free tail.
    void RunGrowthChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        constexpr size_t Mebibyte = 1024 * 1024;
        LaxoriLargeObjectSpace space;
        Check(
            space.Initialize(&metadata, StructureBytes, nullptr, Mebibyte) == LaxoriLargeObjectResult::Success,
            "growth space");
        uintptr_t start = space.GetReservationStart();
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == Mebibyte, "growth need with a free tail");
        LaxoriLargeObjectAllocation front;
        Check(space.Allocate(512 * 1024, 8, 0, Owner, &front) == LaxoriLargeObjectResult::Success, "growth front");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte - Mebibyte / 2, "growth need after an allocation");
        Check(
            metadata.CommitDataRange(start + Mebibyte, 3 * Mebibyte) == SideMetadataResult::Success,
            "growth commit of metadata");
        Check(space.GrowQuiescent(Mebibyte) == LaxoriLargeObjectResult::InvalidArgument, "growth does not shrink");
#if defined(HOST_UNIX) && !defined(LAXORI_LOS_PORTABLE_COMMIT)
        // A commit failure leaves the space as it was, and the growth works when it is repeated.
        LaxoriTestFailCommitAfter(0);
        Check(space.GrowQuiescent(4 * Mebibyte) == LaxoriLargeObjectResult::CommitFailed, "growth commit failure");
        LaxoriTestFailCommitAfter(-1);
        Check(space.GetAdmittedBytes() == Mebibyte, "admitted bytes after the growth failure");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte - Mebibyte / 2, "growth need after the growth failure");
#endif
        Check(space.GrowQuiescent(4 * Mebibyte) == LaxoriLargeObjectResult::Success, "growth");
        Check(space.GetAdmittedBytes() == 4 * Mebibyte, "admitted bytes after growth");
        Check(
            space.GetRequiredGrowthBytes(8 * Mebibyte) == 8 * Mebibyte - (4 * Mebibyte - Mebibyte / 2),
            "growth need after growth");
        LaxoriLargeObjectAllocation rest;
        Check(space.Allocate(4 * Mebibyte - Mebibyte / 2, 8, 0, Owner, &rest) == LaxoriLargeObjectResult::Success, "growth rest");
        Check(rest.page_start == start + Mebibyte / 2, "grown pages merge with the free tail");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte, "growth need with no free tail");
        size_t active;
        size_t freePages;
        Check(
            space.ValidateStructure(&active, &freePages) == LaxoriLargeObjectResult::Success && active == 2 && freePages == 0,
            "growth structure");
        space.Shutdown();
    }

    // Threads allocate, look up and release together. The page ranges must stay apart, the lookups must return a whole
    // allocation or none, and at the end all pages must be free in one span.
    void RunConcurrentChecks(SideMetadataManager& metadata)
    {
        constexpr size_t Threads = 8;
        constexpr size_t PerThread = 10;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "concurrent space");
        uintptr_t start = space.GetReservationStart();
        std::atomic<bool> stop{false};
        std::atomic<size_t> inconsistent{0};
        std::atomic<size_t> hits{0};
        std::vector<std::thread> readers;
        for (size_t reader = 0; reader < 2; reader++)
        {
            readers.emplace_back([&, reader]()
            {
                Random random{1000 + reader};
                while (!stop.load(std::memory_order_acquire))
                {
                    uintptr_t address = start + (static_cast<uintptr_t>(random.Next()) % StructureBytes);
                    LaxoriLargeObjectAllocation found;
                    if (space.GetContainingAllocation(address, &found) == LaxoriLargeObjectResult::Success)
                    {
                        hits.fetch_add(1, std::memory_order_relaxed);
                        LaxoriLargeObjectAllocation exact;
                        bool whole = found.object_bytes >= 32768 && found.object_bytes <= 140000 &&
                            found.owner >= 0x3000 && found.owner < 0x3000 + Threads &&
                            address >= found.object && address - found.object < found.object_bytes &&
                            found.page_start >= start && found.object == found.page_start &&
                            found.page_count == (found.object_bytes + Page - 1) / Page &&
                            space.GetAllocation(found.object, &exact) != LaxoriLargeObjectResult::NotInitialized;
                        if (!whole)
                        {
                            inconsistent.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                    if (space.GetAllocation(address & ~(Page - 1), &found) == LaxoriLargeObjectResult::Success &&
                        found.object != (address & ~(Page - 1)))
                    {
                        inconsistent.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            });
        }

        for (int round = 0; round < 40; round++)
        {
            std::vector<std::vector<LaxoriLargeObjectAllocation>> allocations(Threads);
            std::atomic<size_t> failures{0};
            std::vector<std::thread> workers;
            for (size_t index = 0; index < Threads; index++)
            {
                workers.emplace_back([&, index]()
                {
                    Random random{static_cast<uint64_t>(round * 100 + index)};
                    for (size_t count = 0; count < PerThread; count++)
                    {
                        LaxoriLargeObjectAllocation allocation;
                        size_t bytes = 32768 + random.Next() % 100000;
                        if (space.Allocate(bytes, 8, 0, 0x3000 + index, &allocation) != LaxoriLargeObjectResult::Success)
                        {
                            failures.fetch_add(1, std::memory_order_relaxed);
                            continue;
                        }
                        allocations[index].push_back(allocation);
                        LaxoriLargeObjectAllocation found;
                        if (space.GetAllocation(allocation.object, &found) != LaxoriLargeObjectResult::Success ||
                            found.owner != allocation.owner)
                        {
                            failures.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                });
            }
            for (std::thread& worker : workers)
            {
                worker.join();
            }
            std::vector<LaxoriLargeObjectAllocation> all;
            for (const auto& list : allocations)
            {
                all.insert(all.end(), list.begin(), list.end());
            }
            bool overlap = false;
            for (size_t left = 0; left < all.size() && !overlap; left++)
            {
                for (size_t right = left + 1; right < all.size(); right++)
                {
                    overlap = overlap || Overlap(all[left], all[right]);
                }
            }
            Check(failures.load() == 0, "concurrent allocations succeed");
            Check(!overlap, "concurrent allocations do not overlap");
            CheckStructure(space, all, "concurrent structure");

            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "concurrent begin release");
            std::atomic<size_t> releaseFailures{0};
            std::vector<std::thread> releasers;
            for (size_t index = 0; index < Threads; index++)
            {
                releasers.emplace_back([&, index]()
                {
                    for (const LaxoriLargeObjectAllocation& allocation : allocations[index])
                    {
                        if (space.TryRelease(allocation.object, allocation.owner) != LaxoriLargeObjectResult::Success)
                        {
                            releaseFailures.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                });
            }
            for (std::thread& releaser : releasers)
            {
                releaser.join();
            }
            Check(releaseFailures.load() == 0, "concurrent releases succeed");
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "concurrent end release");
            CheckStructure(space, std::vector<LaxoriLargeObjectAllocation>(), "concurrent structure after release");
        }
        stop.store(true, std::memory_order_release);
        for (std::thread& reader : readers)
        {
            reader.join();
        }
        Check(inconsistent.load() == 0, "concurrent lookups return whole allocations");
        Check(hits.load() != 0, "concurrent lookups find allocations");
        LaxoriLargeObjectAllocation whole;
        Check(
            space.Allocate(StructureBytes, 8, 0, 0x3000, &whole) == LaxoriLargeObjectResult::Success &&
                whole.page_start == start,
            "concurrent releases merge into one span");
        space.Shutdown();
    }

    // The young list (the spans allocated since the last pause that are still young) and the running totals of the mature
    // large objects. mode 0: the default. mode 1: the validation mode (every sweep and every statistics call is compared with
    // a full walk of the spans). mode 2: the old walks (the list and the totals are off).
    void RunYoungAndTotalsChecks(SideMetadataManager& metadata, int mode)
    {
        constexpr uintptr_t Owner = 0x2500;
        unsetenv("LAXORI_LOS_VALIDATE");
        unsetenv("LAXORI_LOS_LEGACY_WALKS");
        if (mode == 1)
        {
            setenv("LAXORI_LOS_VALIDATE", "1", 1);
        }
        else if (mode == 2)
        {
            setenv("LAXORI_LOS_LEGACY_WALKS", "1", 1);
        }
        const bool listKept = mode != 2;
        LaxoriLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LaxoriLargeObjectResult::Success, "young space");
        unsetenv("LAXORI_LOS_VALIDATE");
        unsetenv("LAXORI_LOS_LEGACY_WALKS");

        struct Entry
        {
            LaxoriLargeObjectAllocation allocation;
            bool mature;
        };
        std::vector<Entry> live;

        auto objectOf = [](const Entry& entry) { return entry.allocation.object; };
        auto youngObjects = [&](size_t* entries)
        {
            std::vector<uintptr_t> objects(StructurePages);
            size_t count = 0;
            Check(
                space.GetYoungObjects(objects.data(), objects.size(), &count, entries) == LaxoriLargeObjectResult::Success,
                "young list read");
            objects.resize(count);
            std::sort(objects.begin(), objects.end());
            return objects;
        };
        // The list holds exactly the young allocations of the model. After a sweep it has no stale entry either.
        auto expectYoung = [&](const char* name, bool afterSweep)
        {
            if (!listKept)
            {
                return;
            }
            std::vector<uintptr_t> expected;
            for (const Entry& entry : live)
            {
                if (!entry.mature)
                {
                    expected.push_back(objectOf(entry));
                }
            }
            std::sort(expected.begin(), expected.end());
            size_t entries = 0;
            std::vector<uintptr_t> actual = youngObjects(&entries);
            Check(actual == expected, name);
            if (afterSweep)
            {
                Check(entries == expected.size(), "the sweep leaves no stale entry in the young list");
            }
        };
        auto checkTotals = [&](const char* name)
        {
            size_t modelBytes = 0;
            size_t modelSlack = 0;
            for (const Entry& entry : live)
            {
                if (entry.mature)
                {
                    modelBytes += entry.allocation.page_count * Page;
                    modelSlack += entry.allocation.page_count * Page - entry.allocation.object_bytes;
                }
            }
            size_t bytes = SIZE_MAX;
            size_t slack = SIZE_MAX;
            size_t walkBytes = SIZE_MAX;
            size_t walkSlack = SIZE_MAX;
            Check(space.GetMatureStatistics(&bytes, &slack) == LaxoriLargeObjectResult::Success, name);
            Check(space.GetMatureStatisticsByWalk(&walkBytes, &walkSlack) == LaxoriLargeObjectResult::Success, name);
            Check(bytes == walkBytes && slack == walkSlack, "the mature totals equal a full walk");
            Check(bytes == modelBytes && slack == modelSlack, "the mature totals equal the model");
            Check(space.GetValidationFailures() == 0, "the validation mode reports no difference");
        };
        auto setCount = [&](const LaxoriLargeObjectAllocation& allocation, uintptr_t value)
        {
            Check(
                metadata.Store(
                    LaxoriSideMetadataKind::ReferenceCount, allocation.object, value,
                    SideMetadataMemoryOrder::SequentiallyConsistent) == SideMetadataResult::Success,
                "young set count");
        };
        auto allocate = [&](size_t bytes)
        {
            LaxoriLargeObjectAllocation allocation;
            Check(space.Allocate(bytes, 8, 0, Owner, &allocation) == LaxoriLargeObjectResult::Success, "young allocate");
            live.push_back({allocation, false});
            return allocation;
        };
        auto pages = [](const LaxoriLargeObjectAllocation& allocation) { return allocation.page_count * Page; };
        auto erase = [&](uintptr_t object)
        {
            live.erase(
                std::remove_if(live.begin(), live.end(), [&](const Entry& entry) { return objectOf(entry) == object; }),
                live.end());
        };
        auto promote = [&](const LaxoriLargeObjectAllocation& allocation)
        {
            bool updated = false;
            Check(
                space.TryMarkAndPromote(allocation.object, Owner, &updated) == LaxoriLargeObjectResult::Success && updated,
                "young promote");
            for (Entry& entry : live)
            {
                if (objectOf(entry) == allocation.object)
                {
                    entry.mature = true;
                }
            }
        };

        // One pause by hand. a0 and a1 survive and are promoted, a2 has a count but no promotion, a3 to a5 are dead.
        const size_t sizes[] = {40000, 100000, 32768, 65536, 32769, 200000};
        LaxoriLargeObjectAllocation a[6];
        for (size_t index = 0; index < 6; index++)
        {
            a[index] = allocate(sizes[index]);
        }
        expectYoung("the young list has the six new spans", false);
        checkTotals("the totals before a promotion");
        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "young begin release");
        setCount(a[0], 1);
        setCount(a[1], 1);
        setCount(a[2], 1);
        promote(a[0]);
        promote(a[1]);
        size_t released = SIZE_MAX;
        Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::Success, "young sweep");
        Check(released == pages(a[3]) + pages(a[4]) + pages(a[5]), "the sweep releases the dead young spans");
        erase(a[3].object);
        erase(a[4].object);
        erase(a[5].object);
        expectYoung("promoted and dead spans leave the young list, a span with a count stays", true);
        auto allAllocations = [&]()
        {
            std::vector<LaxoriLargeObjectAllocation> all;
            for (const Entry& entry : live)
            {
                all.push_back(entry.allocation);
            }
            return all;
        };
        CheckStructure(space, allAllocations(), "young structure after the first pause");
        checkTotals("the totals after the first pause");
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "young end release");

        // The next pause: a2 is promoted now, and two new spans are dead.
        LaxoriLargeObjectAllocation b0 = allocate(50000);
        LaxoriLargeObjectAllocation b1 = allocate(70000);
        expectYoung("the list has the survivor and the new spans", false);
        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "young second begin release");
        promote(a[2]);
        Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::Success, "young second sweep");
        Check(released == pages(b0) + pages(b1), "the second sweep releases the two dead spans");
        erase(b0.object);
        erase(b1.object);
        expectYoung("the list is empty after the second pause", true);
        checkTotals("the totals after the second pause");
        // A mature large object that dies leaves the totals.
        Check(space.TryRelease(a[0].object, Owner) == LaxoriLargeObjectResult::Success, "young release of a mature span");
        erase(a[0].object);
        checkTotals("the totals after a release of a mature span");
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "young second end release");

        // A failed decommit keeps the dead young spans in the list; the next sweep releases them.
        LaxoriLargeObjectAllocation c0 = allocate(40000);
        LaxoriLargeObjectAllocation c1 = allocate(40000);
        LaxoriLargeObjectAllocation c2 = allocate(40000);
        Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "young failure begin release");
        LaxoriTestFailDecommitAfter(0);
        Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::DecommitFailed, "young sweep with a decommit failure");
        LaxoriTestFailDecommitAfter(-1);
        expectYoung("a failed release keeps the spans in the young list", true);
        Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::Success, "young sweep after the failure");
        Check(released == pages(c0) + pages(c1) + pages(c2), "the second sweep releases the spans of the failure");
        erase(c0.object);
        erase(c1.object);
        erase(c2.object);
        expectYoung("the list is empty after the repeated sweep", true);
        checkTotals("the totals after the decommit failure");
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "young failure end release");

        // Allocations and releases between the pauses: the stale entries do not pile up.
        for (int cycle = 0; cycle < 3000; cycle++)
        {
            LaxoriLargeObjectAllocation transient = allocate(32768);
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "young cycle begin release");
            Check(space.TryRelease(transient.object, Owner) == LaxoriLargeObjectResult::Success, "young cycle release");
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "young cycle end release");
            erase(transient.object);
        }
        {
            size_t entries = 0;
            youngObjects(&entries);
            Check(!listKept || entries <= 2048, "stale entries of the young list stay bounded");
        }

        // Random pauses against a model.
        Random random{4747};
        for (int round = 0; round < 400; round++)
        {
            size_t allocations = random.Next() % 7;
            for (size_t index = 0; index < allocations; index++)
            {
                LaxoriLargeObjectAllocation allocation;
                size_t bytes = 32768 + random.Next() % 150000;
                if (space.Allocate(bytes, 8, 0, Owner, &allocation) == LaxoriLargeObjectResult::Success)
                {
                    live.push_back({allocation, false});
                }
            }
            expectYoung("random: the list has the young spans", false);
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "random young begin release");
            size_t expectedReleased = 0;
            std::vector<uintptr_t> dead;
            std::vector<Entry> snapshot = live;
            for (const Entry& entry : snapshot)
            {
                if (entry.mature)
                {
                    continue;
                }
                uint32_t roll = random.Next() % 10;
                if (roll < 4)
                {
                    setCount(entry.allocation, 1);
                    promote(entry.allocation);
                }
                else if (roll < 6)
                {
                    setCount(entry.allocation, 1);
                }
                else if (roll == 6)
                {
                    // A young span that a thread releases itself before the sweep: its entry is stale.
                    Check(space.TryRelease(entry.allocation.object, Owner) == LaxoriLargeObjectResult::Success, "random young release");
                    erase(entry.allocation.object);
                }
                else
                {
                    setCount(entry.allocation, 0);
                    dead.push_back(entry.allocation.object);
                    expectedReleased += entry.allocation.page_count * Page;
                }
            }
            for (uintptr_t object : dead)
            {
                erase(object);
            }
            // A few mature spans die.
            std::vector<uintptr_t> mature;
            for (const Entry& entry : live)
            {
                if (entry.mature && random.Next() % 4 == 0)
                {
                    mature.push_back(objectOf(entry));
                }
            }
            for (uintptr_t object : mature)
            {
                Check(space.TryRelease(object, Owner) == LaxoriLargeObjectResult::Success, "random young mature release");
                erase(object);
            }
            Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::Success, "random young sweep");
            Check(released == expectedReleased, "random sweep releases exactly the dead young spans");
            expectYoung("random: promoted, dead and released spans left the list", true);
            checkTotals("random totals");
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "random young end release");
            if (round % 20 == 0)
            {
                CheckStructure(space, allAllocations(), "random young structure");
            }
        }

        // Threads allocate together: the list has every span, and the sweep releases all dead ones.
        {
            constexpr size_t Threads = 8;
            std::vector<std::vector<LaxoriLargeObjectAllocation>> allocations(Threads);
            std::vector<std::thread> workers;
            for (size_t index = 0; index < Threads; index++)
            {
                workers.emplace_back([&, index]()
                {
                    Random threadRandom{900 + index};
                    for (size_t count = 0; count < 6; count++)
                    {
                        LaxoriLargeObjectAllocation allocation;
                        if (space.Allocate(32768 + threadRandom.Next() % 60000, 8, 0, Owner, &allocation) ==
                            LaxoriLargeObjectResult::Success)
                        {
                            allocations[index].push_back(allocation);
                        }
                    }
                });
            }
            for (std::thread& worker : workers)
            {
                worker.join();
            }
            for (const auto& list : allocations)
            {
                for (const LaxoriLargeObjectAllocation& allocation : list)
                {
                    live.push_back({allocation, false});
                }
            }
            expectYoung("the list has the spans of all threads", false);
            Check(space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success, "threads young begin release");
            Check(space.SweepNursery(&released) == LaxoriLargeObjectResult::Success, "threads young sweep");
            for (const auto& list : allocations)
            {
                for (const LaxoriLargeObjectAllocation& allocation : list)
                {
                    erase(allocation.object);
                }
            }
            expectYoung("the list is empty after the sweep of the threads", true);
            checkTotals("the totals after the threads");
            Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "threads young end release");
        }
        space.Shutdown();
    }
}

int main()
{
#ifndef HOST_64BIT
    LaxoriSideMetadataLayout unsupported;
    Check(
        LaxoriSideMetadataLayout::Create(1, &unsupported) ==
            SideMetadataResult::UnsupportedAddressSpace,
        "x86 fails closed");
    std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
    return s_failures == 0 ? 0 : 1;
#else
    Check(!LaxoriLargeObjectSpace::ShouldUseLargeObjectSpace(32767), "threshold minus one");
    Check(LaxoriLargeObjectSpace::ShouldUseLargeObjectSpace(32768), "threshold exact");
    Check(LaxoriLargeObjectSpace::ShouldUseLargeObjectSpace(32769), "threshold plus one");
    if (s_failures != 0)
    {
        std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
        return 1;
    }

    LaxoriLargeObjectAllocation geometry;
    Check(
        LaxoriLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            32768,
            64,
            8,
            &geometry) == LaxoriLargeObjectResult::Success,
        "geometry aligned");
    Check(((geometry.object + 8) & 63) == 0, "geometry offset alignment");
    Check(geometry.page_count == 9, "geometry page count");
    Check(
        LaxoriLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            32768,
            LaxoriLargeObjectSpace::PageBytes * 2,
            0,
            &geometry) == LaxoriLargeObjectResult::InvalidArgument,
        "geometry rejects super-page alignment");
    Check(
        LaxoriLargeObjectSpace::ComputeAllocationGeometry(
            LaxoriSideMetadataLayout::AddressLimit - LaxoriLargeObjectSpace::PageBytes,
            32768,
            8,
            0,
            &geometry) == LaxoriLargeObjectResult::AddressOverflow,
        "geometry address limit");
    Check(
        LaxoriLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            SIZE_MAX,
            8,
            0,
            &geometry) == LaxoriLargeObjectResult::AddressOverflow,
        "geometry size overflow");

    for (uint8_t rcWidth = 1; rcWidth <= 3; rcWidth++)
    {
        LaxoriSideMetadataLayout layout;
        Check(
            LaxoriSideMetadataLayout::Create(rcWidth, &layout) == SideMetadataResult::Success,
            "layout creation");

        SideMetadataManager metadata;
        Check(
            metadata.Initialize(&layout) == SideMetadataResult::Success,
            "metadata initialization");

        LaxoriLargeObjectSpace initializationSpace;
        std::atomic<LaxoriLargeObjectResult> firstInitialization;
        std::atomic<LaxoriLargeObjectResult> secondInitialization;
        std::thread firstInitializer([&]()
        {
            firstInitialization.store(
                initializationSpace.Initialize(&metadata, 16 * 1024 * 1024),
                std::memory_order_relaxed);
        });
        std::thread secondInitializer([&]()
        {
            secondInitialization.store(
                initializationSpace.Initialize(&metadata, 16 * 1024 * 1024),
                std::memory_order_relaxed);
        });
        firstInitializer.join();
        secondInitializer.join();
        LaxoriLargeObjectResult firstResult =
            firstInitialization.load(std::memory_order_relaxed);
        LaxoriLargeObjectResult secondResult =
            secondInitialization.load(std::memory_order_relaxed);
        Check(
            ((firstResult == LaxoriLargeObjectResult::Success) &&
             (secondResult == LaxoriLargeObjectResult::InvalidPhase)) ||
                ((firstResult == LaxoriLargeObjectResult::InvalidPhase) &&
                 (secondResult == LaxoriLargeObjectResult::Success)),
            "concurrent initialization has one winner");
        initializationSpace.Shutdown();

        LaxoriLargeObjectSpace space;
        Check(
            space.Initialize(&metadata, 16 * 1024 * 1024) ==
                LaxoriLargeObjectResult::Success,
            "space initialization");

        constexpr uintptr_t Owner = 0x2500;
        LaxoriLargeObjectAllocation below;
        Check(
            space.Allocate(32767, 8, 0, Owner, &below) ==
                LaxoriLargeObjectResult::BelowThreshold,
            "allocation threshold minus one");

        LaxoriLargeObjectAllocation first;
        Check(
            space.Allocate(32768, 8, 0, Owner, &first) ==
                LaxoriLargeObjectResult::Success,
            "allocation threshold exact");
        Check(first.page_count == 8, "exact threshold pages");
        Check(
            reinterpret_cast<uint8_t*>(first.object)[0] == 0 &&
                reinterpret_cast<uint8_t*>(first.object)[first.object_bytes - 1] == 0,
            "fresh allocation zero");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectMarkNursery, first.object) ==
                LaxoriLargeObjectSpace::NurseryBit,
            "fresh nursery state");
#ifdef LAXORI_OBJECT_START_WALK
        // The walk variant never writes the ValidObject plane: a large object is found by its allocation record.
        Check(
            Load(metadata, LaxoriSideMetadataKind::ValidObject, first.object) == 0,
            "fresh object leaves the ValidObject plane alone");
#else
        Check(
            Load(metadata, LaxoriSideMetadataKind::ValidObject, first.object) == 1,
            "fresh valid object");
#endif // LAXORI_OBJECT_START_WALK
        Check(
            Load(metadata, LaxoriSideMetadataKind::ReferenceCount, first.object) == 0,
            "fresh reference count");
        Check(
            Load(metadata, LaxoriSideMetadataKind::FieldUnlogged, first.object) == 0,
            "fresh field log");
        Check(
            space.TryRelease(first.object, Owner) == LaxoriLargeObjectResult::InvalidPhase,
            "release phase restriction");

        std::memset(
            reinterpret_cast<void*>(first.object),
            0xa5,
            first.object_bytes);
        Check(
            space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success,
            "begin release collection");
        Check(
            space.TryRelease(first.object, Owner + 1) == LaxoriLargeObjectResult::NotOwner,
            "release owner restriction");
        Check(
            space.TryRelease(first.object, Owner) == LaxoriLargeObjectResult::Success,
            "release first");
        Check(
            space.EndCollection() == LaxoriLargeObjectResult::Success,
            "end release collection");

        uintptr_t neighboringPage = first.page_start +
            (first.page_count * LaxoriLargeObjectSpace::PageBytes);
        Check(
            metadata.Store(
                LaxoriSideMetadataKind::LargeObjectPageReuse,
                first.page_start,
                UINT8_MAX,
                SideMetadataMemoryOrder::SequentiallyConsistent) ==
                SideMetadataResult::Success,
            "seed reuse wrap");
        Check(
            metadata.Store(
                LaxoriSideMetadataKind::LargeObjectPageReuse,
                neighboringPage,
                17,
                SideMetadataMemoryOrder::SequentiallyConsistent) ==
                SideMetadataResult::Success,
            "seed neighboring reuse");

        Check(
            space.BeginCollection(true, true) == LaxoriLargeObjectResult::Success,
            "begin concurrent full trace");
        LaxoriLargeObjectAllocation recycled;
        Check(
            space.Allocate(32768, 8, 0, Owner, &recycled) ==
                LaxoriLargeObjectResult::Success,
            "recycled allocation");
        Check(recycled.page_start == first.page_start, "recycled address");
        Check(
            reinterpret_cast<uint8_t*>(recycled.object)[0] == 0 &&
                reinterpret_cast<uint8_t*>(recycled.object)[recycled.object_bytes - 1] == 0,
            "recycled allocation zero");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectPageReuse, recycled.page_start) == 0,
            "reuse wraps");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectPageReuse, neighboringPage) == 17,
            "neighboring reuse unchanged");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectMarkNursery, recycled.object) ==
                (LaxoriLargeObjectSpace::MarkBit | LaxoriLargeObjectSpace::NurseryBit),
            "concurrent nursery marked");

        bool updated;
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LaxoriLargeObjectResult::InvalidPhase,
            "promotion phase restriction");
        Check(space.BeginRelease() == LaxoriLargeObjectResult::Success, "begin release");
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LaxoriLargeObjectResult::Success &&
                updated,
            "mark and promote");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectMarkNursery, recycled.object) ==
                LaxoriLargeObjectSpace::MarkBit,
            "promoted state");
        Check(
            Load(metadata, LaxoriSideMetadataKind::FieldUnlogged, recycled.object) == 1,
            "promotion initializes field log");
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LaxoriLargeObjectResult::Success &&
                !updated,
            "mark and promote idempotent");
        Check(
            space.TryRelease(recycled.object, Owner) == LaxoriLargeObjectResult::Success,
            "release recycled");
        Check(space.EndCollection() == LaxoriLargeObjectResult::Success, "end collection");

        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectMarkNursery, recycled.object) == 0,
            "release clears mark nursery");
        Check(
            Load(metadata, LaxoriSideMetadataKind::ValidObject, recycled.object) == 0,
            "release clears valid object");
        Check(
            Load(metadata, LaxoriSideMetadataKind::LargeObjectPageReuse, recycled.page_start) == 0,
            "release preserves reuse");

        LaxoriLargeObjectAllocation thresholdPlusOne;
        Check(
            space.Allocate(32769, 8, 0, Owner, &thresholdPlusOne) ==
                LaxoriLargeObjectResult::Success,
            "threshold plus one allocation");
        Check(thresholdPlusOne.object_bytes == 32769, "threshold plus one logical size");
        Check(thresholdPlusOne.page_count == 9, "threshold plus one page span");
        Check(
            Load(
                metadata,
                LaxoriSideMetadataKind::LargeObjectMarkNursery,
                thresholdPlusOne.object) ==
                (LaxoriLargeObjectSpace::MarkBit | LaxoriLargeObjectSpace::NurseryBit),
            "threshold plus one nursery state");
        Check(
            space.BeginCollection(false, false) == LaxoriLargeObjectResult::Success,
            "threshold plus one begin release");
        Check(
            space.TryMarkAndPromote(thresholdPlusOne.object, Owner, &updated) ==
                LaxoriLargeObjectResult::Success &&
                updated,
            "threshold plus one promote");
        Check(
            Load(
                metadata,
                LaxoriSideMetadataKind::FieldUnlogged,
                thresholdPlusOne.object) == 1,
            "threshold plus one first field log");
        Check(
            Load(
                metadata,
                LaxoriSideMetadataKind::FieldUnlogged,
                thresholdPlusOne.object + 32768) == 1,
            "threshold plus one rounded field log");
        Check(
            Load(
                metadata,
                LaxoriSideMetadataKind::LargeObjectMarkNursery,
                thresholdPlusOne.object) == LaxoriLargeObjectSpace::MarkBit,
            "threshold plus one promoted state");
        Check(
            space.TryRelease(thresholdPlusOne.object, Owner) ==
                LaxoriLargeObjectResult::Success,
            "threshold plus one release");
        Check(
            space.EndCollection() == LaxoriLargeObjectResult::Success,
            "threshold plus one end collection");

        space.Shutdown();
        RunLookupChecks(metadata);
        RunFreeSpanChecks(metadata);
        RunRandomChecks(metadata);
        RunFailureChecks(metadata);
        RunGrowthChecks(metadata);
        RunConcurrentChecks(metadata);
        RunYoungAndTotalsChecks(metadata, 0);
        RunYoungAndTotalsChecks(metadata, 1);
        RunYoungAndTotalsChecks(metadata, 2);
        metadata.Shutdown();
    }

    std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
    return s_failures == 0 ? 0 : 1;
#endif
}
