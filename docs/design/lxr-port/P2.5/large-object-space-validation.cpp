// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc/env/common.h"
#include "../../../../src/coreclr/gc/env/gcenv.h"
#include "../../../../src/coreclr/gc_lxr/large_object_space.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

void LxrTestFailCommitAfter(int64_t calls);
void LxrTestFailDecommitAfter(int64_t calls);

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
        LxrSideMetadataKind kind,
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

    constexpr size_t Page = LxrLargeObjectSpace::PageBytes;
    constexpr size_t StructureBytes = 16 * 1024 * 1024;
    constexpr size_t StructurePages = StructureBytes / Page;

    // The allocations that are alive, the structure of the space, and the pages that are free must agree.
    void CheckStructure(
        const LxrLargeObjectSpace& space, const std::vector<LxrLargeObjectAllocation>& live, const char* name)
    {
        size_t activePages = 0;
        for (const LxrLargeObjectAllocation& allocation : live)
        {
            activePages += allocation.page_count;
        }
        size_t active = SIZE_MAX;
        size_t freePages = SIZE_MAX;
        Check(space.ValidateStructure(&active, &freePages) == LxrLargeObjectResult::Success, name);
        Check(active == live.size(), "structure active count");
        Check(freePages == StructurePages - activePages, "structure free pages");
    }

    bool Overlap(const LxrLargeObjectAllocation& left, const LxrLargeObjectAllocation& right)
    {
        return left.page_start < right.page_start + right.page_count * Page &&
            right.page_start < left.page_start + left.page_count * Page;
    }

    void CheckLookups(const LxrLargeObjectSpace& space, const LxrLargeObjectAllocation& expected)
    {
        LxrLargeObjectAllocation found;
        Check(
            space.GetAllocation(expected.object, &found) == LxrLargeObjectResult::Success &&
                found.object == expected.object && found.page_start == expected.page_start &&
                found.object_bytes == expected.object_bytes && found.page_count == expected.page_count &&
                found.padding_bytes == expected.padding_bytes && found.owner == expected.owner,
            "lookup by object");
        Check(
            space.GetAllocation(expected.object + 8, &found) == LxrLargeObjectResult::NotFound,
            "lookup by interior address is not an object lookup");
        Check(
            space.GetContainingAllocation(expected.object, &found) == LxrLargeObjectResult::Success &&
                found.object == expected.object,
            "containing lookup of the first byte");
        Check(
            space.GetContainingAllocation(expected.object + expected.object_bytes - 1, &found) ==
                    LxrLargeObjectResult::Success &&
                found.object == expected.object && found.owner == expected.owner,
            "containing lookup of the last byte");
        Check(
            space.GetContainingAllocation(expected.object + expected.object_bytes / 2, &found) ==
                    LxrLargeObjectResult::Success &&
                found.object == expected.object,
            "containing lookup of the middle");
        if (expected.padding_bytes != 0)
        {
            Check(
                space.GetContainingAllocation(expected.page_start, &found) == LxrLargeObjectResult::NotFound,
                "containing lookup of the padding");
            Check(
                space.GetAllocation(expected.page_start, &found) == LxrLargeObjectResult::NotFound,
                "lookup of the page start before the object");
        }
        uintptr_t end = expected.object + expected.object_bytes;
        if (end < expected.page_start + expected.page_count * Page)
        {
            Check(
                space.GetContainingAllocation(end, &found) == LxrLargeObjectResult::NotFound,
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
        LxrLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LxrLargeObjectResult::Success, "lookup space");
        uintptr_t start = space.GetReservationStart();
        std::vector<LxrLargeObjectAllocation> live;
        const size_t sizes[] = {40000, 100000, 32768, 65536, 32769};
        for (size_t size : sizes)
        {
            LxrLargeObjectAllocation allocation;
            Check(space.Allocate(size, 8, 0, Owner, &allocation) == LxrLargeObjectResult::Success, "lookup allocate");
            live.push_back(allocation);
        }
        // An allocation with padding in front of the object: the object starts after the first bytes of its first page.
        LxrLargeObjectAllocation padded;
        Check(
            space.Allocate(50000, 64, 8, Owner + 1, &padded) == LxrLargeObjectResult::Success &&
                padded.padding_bytes != 0 && ((padded.object + 8) & 63) == 0,
            "lookup padded allocate");
        live.push_back(padded);
        for (const LxrLargeObjectAllocation& allocation : live)
        {
            CheckLookups(space, allocation);
        }
        CheckStructure(space, live, "lookup structure");

        LxrLargeObjectAllocation found;
        Check(space.GetAllocation(start - 8, &found) == LxrLargeObjectResult::NotFound, "lookup below the reservation");
        Check(space.GetAllocation(start + StructureBytes, &found) == LxrLargeObjectResult::NotFound, "lookup above the reservation");
        Check(space.GetContainingAllocation(UINTPTR_MAX, &found) == LxrLargeObjectResult::NotFound, "containing lookup of the top");
        Check(space.GetContainingAllocation(0, &found) == LxrLargeObjectResult::NotFound, "containing lookup of zero");
        const LxrLargeObjectAllocation& last = live.back();
        Check(
            space.GetContainingAllocation(last.page_start + last.page_count * Page + 16, &found) ==
                LxrLargeObjectResult::NotFound,
            "containing lookup of a free page");

        // The lookups of a released allocation fail, and the neighbours stay.
        Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "lookup begin release");
        LxrLargeObjectAllocation victim = live[1];
        Check(space.TryRelease(victim.object, Owner) == LxrLargeObjectResult::Success, "lookup release");
        Check(space.TryRelease(victim.object, Owner) == LxrLargeObjectResult::NotFound, "double release");
        Check(space.GetAllocation(victim.object, &found) == LxrLargeObjectResult::NotFound, "lookup after release");
        Check(
            space.GetContainingAllocation(victim.object + 8, &found) == LxrLargeObjectResult::NotFound,
            "containing lookup after release");
        live.erase(live.begin() + 1);
        for (const LxrLargeObjectAllocation& allocation : live)
        {
            CheckLookups(space, allocation);
        }
        bool updated;
        Check(
            space.TryMarkAndPromote(victim.object, Owner, &updated) == LxrLargeObjectResult::NotFound,
            "promote after release");
        Check(space.EndCollection() == LxrLargeObjectResult::Success, "lookup end release");
        CheckStructure(space, live, "lookup structure after release");
        space.Shutdown();
        Check(space.GetAllocation(live[0].object, &found) == LxrLargeObjectResult::NotInitialized, "lookup after shutdown");
    }

    // The first fit by address, the remainder of a free span, and the merge of free neighbours.
    void RunFreeSpanChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LxrLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LxrLargeObjectResult::Success, "free span space");
        uintptr_t start = space.GetReservationStart();
        std::vector<LxrLargeObjectAllocation> live;
        // The pages of the objects: a 10, b 25, c 8, d 16, e 8, f 8.
        const size_t sizes[] = {40000, 100000, 32768, 65536, 32768, 32768};
        LxrLargeObjectAllocation objects[6];
        for (size_t index = 0; index < 6; index++)
        {
            Check(
                space.Allocate(sizes[index], 8, 0, Owner, &objects[index]) == LxrLargeObjectResult::Success,
                "free span allocate");
            Check(
                objects[index].page_start == (index == 0 ? start : objects[index - 1].page_start +
                    objects[index - 1].page_count * Page),
                "allocation takes the lowest address");
            live.push_back(objects[index]);
        }
        Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "free span begin release");
        Check(space.TryRelease(objects[1].object, Owner) == LxrLargeObjectResult::Success, "release b");
        Check(space.TryRelease(objects[3].object, Owner) == LxrLargeObjectResult::Success, "release d");
        live.erase(live.begin() + 3);
        live.erase(live.begin() + 1);
        Check(space.EndCollection() == LxrLargeObjectResult::Success, "free span end release");
        CheckStructure(space, live, "two holes");

        // The first fit by address takes the hole of b (25 pages) for 16 pages, and not the exact hole of d.
        LxrLargeObjectAllocation fromB;
        Check(space.Allocate(65536, 8, 0, Owner, &fromB) == LxrLargeObjectResult::Success, "first fit allocate");
        Check(fromB.page_start == objects[1].page_start, "first fit takes the lowest hole that fits");
        live.push_back(fromB);
        // The remainder of the hole of b is 9 pages, and the next 8 pages start right after fromB.
        LxrLargeObjectAllocation remainder;
        Check(space.Allocate(32768, 8, 0, Owner, &remainder) == LxrLargeObjectResult::Success, "remainder allocate");
        Check(remainder.page_start == fromB.page_start + fromB.page_count * Page, "remainder start");
        live.push_back(remainder);
        // One page is left in the hole of b, so 16 pages go to the hole of d.
        LxrLargeObjectAllocation fromD;
        Check(space.Allocate(65536, 8, 0, Owner, &fromD) == LxrLargeObjectResult::Success, "second hole allocate");
        Check(fromD.page_start == objects[3].page_start, "second hole start");
        live.push_back(fromD);
        CheckStructure(space, live, "after the holes are used");
        // A request that no hole fits goes after the last object.
        LxrLargeObjectAllocation tail;
        Check(space.Allocate(200000, 8, 0, Owner, &tail) == LxrLargeObjectResult::Success, "tail allocate");
        Check(tail.page_start == objects[5].page_start + objects[5].page_count * Page, "tail start");
        live.push_back(tail);
        CheckStructure(space, live, "after the tail allocation");

        // Whatever the order of the releases, all free neighbours merge into one span.
        for (int order = 0; order < 4; order++)
        {
            std::vector<LxrLargeObjectAllocation> victims = live;
            if (order == 1)
            {
                std::reverse(victims.begin(), victims.end());
            }
            else if (order == 2)
            {
                std::vector<LxrLargeObjectAllocation> interleaved;
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
            Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "merge begin release");
            for (const LxrLargeObjectAllocation& victim : victims)
            {
                Check(space.TryRelease(victim.object, Owner) == LxrLargeObjectResult::Success, "merge release");
            }
            Check(space.EndCollection() == LxrLargeObjectResult::Success, "merge end release");
            CheckStructure(space, std::vector<LxrLargeObjectAllocation>(), "all released");
            LxrLargeObjectAllocation whole;
            Check(
                space.Allocate(StructureBytes, 8, 0, Owner, &whole) == LxrLargeObjectResult::Success &&
                    whole.page_start == start && whole.page_count == StructurePages,
                "released neighbours merge into one span");
            Check(space.Allocate(32768, 8, 0, Owner, &whole) == LxrLargeObjectResult::OutOfMemory, "no space left");
            LxrLargeObjectAllocation again;
            Check(space.GetAllocation(start, &again) == LxrLargeObjectResult::Success, "whole lookup");
            Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "whole begin release");
            Check(space.TryRelease(start, Owner) == LxrLargeObjectResult::Success, "whole release");
            Check(space.EndCollection() == LxrLargeObjectResult::Success, "whole end release");
            // Put the objects back for the next order.
            for (LxrLargeObjectAllocation& object : live)
            {
                Check(space.Allocate(object.object_bytes, 8, 0, Owner, &object) == LxrLargeObjectResult::Success, "refill");
            }
            CheckStructure(space, live, "refilled");
        }
        space.Shutdown();
    }

    // Random allocations and releases against a model of the pages.
    void RunRandomChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        LxrLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LxrLargeObjectResult::Success, "random space");
        Random random{12345};
        std::vector<LxrLargeObjectAllocation> live;
        size_t failures = 0;
        for (int round = 0; round < 300; round++)
        {
            size_t allocations = random.Next() % 9;
            for (size_t index = 0; index < allocations; index++)
            {
                size_t bytes = 32768 + (random.Next() % 20 == 0 ? random.Next() % 1500000 : random.Next() % 120000);
                LxrLargeObjectAllocation allocation;
                LxrLargeObjectResult result = space.Allocate(bytes, 8, 0, Owner, &allocation);
                if (result == LxrLargeObjectResult::Success)
                {
                    for (const LxrLargeObjectAllocation& other : live)
                    {
                        Check(!Overlap(allocation, other), "random allocations do not overlap");
                    }
                    live.push_back(allocation);
                }
                else
                {
                    Check(result == LxrLargeObjectResult::OutOfMemory, "random failure is out of memory");
                    failures++;
                }
            }
            Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "random begin release");
            size_t releases = live.empty() ? 0 : random.Next() % (live.size() + 1);
            for (size_t index = 0; index < releases; index++)
            {
                size_t victim = random.Next() % live.size();
                Check(space.TryRelease(live[victim].object, Owner) == LxrLargeObjectResult::Success, "random release");
                live.erase(live.begin() + victim);
            }
            Check(space.EndCollection() == LxrLargeObjectResult::Success, "random end release");
            if (round % 10 == 0)
            {
                CheckStructure(space, live, "random structure");
                for (const LxrLargeObjectAllocation& allocation : live)
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
            LxrLargeObjectAllocation allocation;
            LxrLargeObjectResult result = space.Allocate(100000, 8, 0, Owner, &allocation);
            if (result == LxrLargeObjectResult::Success)
            {
                live.push_back(allocation);
            }
            else
            {
                exhausted = result == LxrLargeObjectResult::OutOfMemory;
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
        LxrLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LxrLargeObjectResult::Success, "failure space");
        std::vector<LxrLargeObjectAllocation> live;
        LxrLargeObjectAllocation first;
        Check(space.Allocate(40000, 8, 0, Owner, &first) == LxrLargeObjectResult::Success, "failure first");
        live.push_back(first);

        LxrLargeObjectAllocation second;
#if !defined(HOST_UNIX) || defined(LXR_LOS_PORTABLE_COMMIT)
        // The Unix space commits the admitted range once, and the other platforms commit the pages of each allocation.
        LxrTestFailCommitAfter(0);
        LxrLargeObjectAllocation failed;
        Check(space.Allocate(100000, 8, 0, Owner, &failed) == LxrLargeObjectResult::CommitFailed, "commit failure");
        LxrTestFailCommitAfter(-1);
        CheckStructure(space, live, "structure after commit failure");
        Check(space.GetCommittedBytes() == first.page_count * Page, "committed bytes after commit failure");
#endif
        Check(space.Allocate(100000, 8, 0, Owner, &second) == LxrLargeObjectResult::Success, "allocate after commit failure");
        Check(second.page_start == first.page_start + first.page_count * Page, "pages of the failed commit are reused");
        live.push_back(second);

        Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "failure begin release");
        LxrTestFailDecommitAfter(0);
        Check(space.TryRelease(first.object, Owner) == LxrLargeObjectResult::DecommitFailed, "decommit failure");
        LxrTestFailDecommitAfter(-1);
        LxrLargeObjectAllocation found;
        Check(
            space.GetAllocation(first.object, &found) == LxrLargeObjectResult::Success && found.owner == Owner,
            "allocation stays after decommit failure");
        CheckStructure(space, live, "structure after decommit failure");
        size_t matureBytes;
        size_t slack;
        Check(space.GetMatureStatistics(&matureBytes, &slack) == LxrLargeObjectResult::Success, "statistics after decommit failure");
        Check(space.TryRelease(first.object, Owner) == LxrLargeObjectResult::Success, "release after decommit failure");
        live.erase(live.begin());
        Check(space.EndCollection() == LxrLargeObjectResult::Success, "failure end release");
        CheckStructure(space, live, "structure after the release");
        Check(space.GetCommittedBytes() == second.page_count * Page, "committed bytes after the release");
        space.Shutdown();
    }

    // The space grows in a quiescent state, and the new pages merge with the free tail.
    void RunGrowthChecks(SideMetadataManager& metadata)
    {
        constexpr uintptr_t Owner = 0x2500;
        constexpr size_t Mebibyte = 1024 * 1024;
        LxrLargeObjectSpace space;
        Check(
            space.Initialize(&metadata, StructureBytes, nullptr, Mebibyte) == LxrLargeObjectResult::Success,
            "growth space");
        uintptr_t start = space.GetReservationStart();
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == Mebibyte, "growth need with a free tail");
        LxrLargeObjectAllocation front;
        Check(space.Allocate(512 * 1024, 8, 0, Owner, &front) == LxrLargeObjectResult::Success, "growth front");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte - Mebibyte / 2, "growth need after an allocation");
        Check(
            metadata.CommitDataRange(start + Mebibyte, 3 * Mebibyte) == SideMetadataResult::Success,
            "growth commit of metadata");
        Check(space.GrowQuiescent(Mebibyte) == LxrLargeObjectResult::InvalidArgument, "growth does not shrink");
#if defined(HOST_UNIX) && !defined(LXR_LOS_PORTABLE_COMMIT)
        // A commit failure leaves the space as it was, and the growth works when it is repeated.
        LxrTestFailCommitAfter(0);
        Check(space.GrowQuiescent(4 * Mebibyte) == LxrLargeObjectResult::CommitFailed, "growth commit failure");
        LxrTestFailCommitAfter(-1);
        Check(space.GetAdmittedBytes() == Mebibyte, "admitted bytes after the growth failure");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte - Mebibyte / 2, "growth need after the growth failure");
#endif
        Check(space.GrowQuiescent(4 * Mebibyte) == LxrLargeObjectResult::Success, "growth");
        Check(space.GetAdmittedBytes() == 4 * Mebibyte, "admitted bytes after growth");
        Check(
            space.GetRequiredGrowthBytes(8 * Mebibyte) == 8 * Mebibyte - (4 * Mebibyte - Mebibyte / 2),
            "growth need after growth");
        LxrLargeObjectAllocation rest;
        Check(space.Allocate(4 * Mebibyte - Mebibyte / 2, 8, 0, Owner, &rest) == LxrLargeObjectResult::Success, "growth rest");
        Check(rest.page_start == start + Mebibyte / 2, "grown pages merge with the free tail");
        Check(space.GetRequiredGrowthBytes(2 * Mebibyte) == 2 * Mebibyte, "growth need with no free tail");
        size_t active;
        size_t freePages;
        Check(
            space.ValidateStructure(&active, &freePages) == LxrLargeObjectResult::Success && active == 2 && freePages == 0,
            "growth structure");
        space.Shutdown();
    }

    // Threads allocate, look up and release together. The page ranges must stay apart, the lookups must return a whole
    // allocation or none, and at the end all pages must be free in one span.
    void RunConcurrentChecks(SideMetadataManager& metadata)
    {
        constexpr size_t Threads = 8;
        constexpr size_t PerThread = 10;
        LxrLargeObjectSpace space;
        Check(space.Initialize(&metadata, StructureBytes) == LxrLargeObjectResult::Success, "concurrent space");
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
                    LxrLargeObjectAllocation found;
                    if (space.GetContainingAllocation(address, &found) == LxrLargeObjectResult::Success)
                    {
                        hits.fetch_add(1, std::memory_order_relaxed);
                        LxrLargeObjectAllocation exact;
                        bool whole = found.object_bytes >= 32768 && found.object_bytes <= 140000 &&
                            found.owner >= 0x3000 && found.owner < 0x3000 + Threads &&
                            address >= found.object && address - found.object < found.object_bytes &&
                            found.page_start >= start && found.object == found.page_start &&
                            found.page_count == (found.object_bytes + Page - 1) / Page &&
                            space.GetAllocation(found.object, &exact) != LxrLargeObjectResult::NotInitialized;
                        if (!whole)
                        {
                            inconsistent.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                    if (space.GetAllocation(address & ~(Page - 1), &found) == LxrLargeObjectResult::Success &&
                        found.object != (address & ~(Page - 1)))
                    {
                        inconsistent.fetch_add(1, std::memory_order_relaxed);
                    }
                }
            });
        }

        for (int round = 0; round < 40; round++)
        {
            std::vector<std::vector<LxrLargeObjectAllocation>> allocations(Threads);
            std::atomic<size_t> failures{0};
            std::vector<std::thread> workers;
            for (size_t index = 0; index < Threads; index++)
            {
                workers.emplace_back([&, index]()
                {
                    Random random{static_cast<uint64_t>(round * 100 + index)};
                    for (size_t count = 0; count < PerThread; count++)
                    {
                        LxrLargeObjectAllocation allocation;
                        size_t bytes = 32768 + random.Next() % 100000;
                        if (space.Allocate(bytes, 8, 0, 0x3000 + index, &allocation) != LxrLargeObjectResult::Success)
                        {
                            failures.fetch_add(1, std::memory_order_relaxed);
                            continue;
                        }
                        allocations[index].push_back(allocation);
                        LxrLargeObjectAllocation found;
                        if (space.GetAllocation(allocation.object, &found) != LxrLargeObjectResult::Success ||
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
            std::vector<LxrLargeObjectAllocation> all;
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

            Check(space.BeginCollection(false, false) == LxrLargeObjectResult::Success, "concurrent begin release");
            std::atomic<size_t> releaseFailures{0};
            std::vector<std::thread> releasers;
            for (size_t index = 0; index < Threads; index++)
            {
                releasers.emplace_back([&, index]()
                {
                    for (const LxrLargeObjectAllocation& allocation : allocations[index])
                    {
                        if (space.TryRelease(allocation.object, allocation.owner) != LxrLargeObjectResult::Success)
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
            Check(space.EndCollection() == LxrLargeObjectResult::Success, "concurrent end release");
            CheckStructure(space, std::vector<LxrLargeObjectAllocation>(), "concurrent structure after release");
        }
        stop.store(true, std::memory_order_release);
        for (std::thread& reader : readers)
        {
            reader.join();
        }
        Check(inconsistent.load() == 0, "concurrent lookups return whole allocations");
        Check(hits.load() != 0, "concurrent lookups find allocations");
        LxrLargeObjectAllocation whole;
        Check(
            space.Allocate(StructureBytes, 8, 0, 0x3000, &whole) == LxrLargeObjectResult::Success &&
                whole.page_start == start,
            "concurrent releases merge into one span");
        space.Shutdown();
    }
}

int main()
{
#ifndef HOST_64BIT
    LxrSideMetadataLayout unsupported;
    Check(
        LxrSideMetadataLayout::Create(1, &unsupported) ==
            SideMetadataResult::UnsupportedAddressSpace,
        "x86 fails closed");
    std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
    return s_failures == 0 ? 0 : 1;
#else
    Check(!LxrLargeObjectSpace::ShouldUseLargeObjectSpace(32767), "threshold minus one");
    Check(LxrLargeObjectSpace::ShouldUseLargeObjectSpace(32768), "threshold exact");
    Check(LxrLargeObjectSpace::ShouldUseLargeObjectSpace(32769), "threshold plus one");
    if (s_failures != 0)
    {
        std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
        return 1;
    }

    LxrLargeObjectAllocation geometry;
    Check(
        LxrLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            32768,
            64,
            8,
            &geometry) == LxrLargeObjectResult::Success,
        "geometry aligned");
    Check(((geometry.object + 8) & 63) == 0, "geometry offset alignment");
    Check(geometry.page_count == 9, "geometry page count");
    Check(
        LxrLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            32768,
            LxrLargeObjectSpace::PageBytes * 2,
            0,
            &geometry) == LxrLargeObjectResult::InvalidArgument,
        "geometry rejects super-page alignment");
    Check(
        LxrLargeObjectSpace::ComputeAllocationGeometry(
            LxrSideMetadataLayout::AddressLimit - LxrLargeObjectSpace::PageBytes,
            32768,
            8,
            0,
            &geometry) == LxrLargeObjectResult::AddressOverflow,
        "geometry address limit");
    Check(
        LxrLargeObjectSpace::ComputeAllocationGeometry(
            UINT64_C(0x0000000200000000),
            SIZE_MAX,
            8,
            0,
            &geometry) == LxrLargeObjectResult::AddressOverflow,
        "geometry size overflow");

    for (uint8_t rcWidth = 1; rcWidth <= 3; rcWidth++)
    {
        LxrSideMetadataLayout layout;
        Check(
            LxrSideMetadataLayout::Create(rcWidth, &layout) == SideMetadataResult::Success,
            "layout creation");

        SideMetadataManager metadata;
        Check(
            metadata.Initialize(&layout) == SideMetadataResult::Success,
            "metadata initialization");

        LxrLargeObjectSpace initializationSpace;
        std::atomic<LxrLargeObjectResult> firstInitialization;
        std::atomic<LxrLargeObjectResult> secondInitialization;
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
        LxrLargeObjectResult firstResult =
            firstInitialization.load(std::memory_order_relaxed);
        LxrLargeObjectResult secondResult =
            secondInitialization.load(std::memory_order_relaxed);
        Check(
            ((firstResult == LxrLargeObjectResult::Success) &&
             (secondResult == LxrLargeObjectResult::InvalidPhase)) ||
                ((firstResult == LxrLargeObjectResult::InvalidPhase) &&
                 (secondResult == LxrLargeObjectResult::Success)),
            "concurrent initialization has one winner");
        initializationSpace.Shutdown();

        LxrLargeObjectSpace space;
        Check(
            space.Initialize(&metadata, 16 * 1024 * 1024) ==
                LxrLargeObjectResult::Success,
            "space initialization");

        constexpr uintptr_t Owner = 0x2500;
        LxrLargeObjectAllocation below;
        Check(
            space.Allocate(32767, 8, 0, Owner, &below) ==
                LxrLargeObjectResult::BelowThreshold,
            "allocation threshold minus one");

        LxrLargeObjectAllocation first;
        Check(
            space.Allocate(32768, 8, 0, Owner, &first) ==
                LxrLargeObjectResult::Success,
            "allocation threshold exact");
        Check(first.page_count == 8, "exact threshold pages");
        Check(
            reinterpret_cast<uint8_t*>(first.object)[0] == 0 &&
                reinterpret_cast<uint8_t*>(first.object)[first.object_bytes - 1] == 0,
            "fresh allocation zero");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectMarkNursery, first.object) ==
                LxrLargeObjectSpace::NurseryBit,
            "fresh nursery state");
        Check(
            Load(metadata, LxrSideMetadataKind::ValidObject, first.object) == 1,
            "fresh valid object");
        Check(
            Load(metadata, LxrSideMetadataKind::ReferenceCount, first.object) == 0,
            "fresh reference count");
        Check(
            Load(metadata, LxrSideMetadataKind::FieldUnlogged, first.object) == 0,
            "fresh field log");
        Check(
            space.TryRelease(first.object, Owner) == LxrLargeObjectResult::InvalidPhase,
            "release phase restriction");

        std::memset(
            reinterpret_cast<void*>(first.object),
            0xa5,
            first.object_bytes);
        Check(
            space.BeginCollection(false, false) == LxrLargeObjectResult::Success,
            "begin release collection");
        Check(
            space.TryRelease(first.object, Owner + 1) == LxrLargeObjectResult::NotOwner,
            "release owner restriction");
        Check(
            space.TryRelease(first.object, Owner) == LxrLargeObjectResult::Success,
            "release first");
        Check(
            space.EndCollection() == LxrLargeObjectResult::Success,
            "end release collection");

        uintptr_t neighboringPage = first.page_start +
            (first.page_count * LxrLargeObjectSpace::PageBytes);
        Check(
            metadata.Store(
                LxrSideMetadataKind::LargeObjectPageReuse,
                first.page_start,
                UINT8_MAX,
                SideMetadataMemoryOrder::SequentiallyConsistent) ==
                SideMetadataResult::Success,
            "seed reuse wrap");
        Check(
            metadata.Store(
                LxrSideMetadataKind::LargeObjectPageReuse,
                neighboringPage,
                17,
                SideMetadataMemoryOrder::SequentiallyConsistent) ==
                SideMetadataResult::Success,
            "seed neighboring reuse");

        Check(
            space.BeginCollection(true, true) == LxrLargeObjectResult::Success,
            "begin concurrent full trace");
        LxrLargeObjectAllocation recycled;
        Check(
            space.Allocate(32768, 8, 0, Owner, &recycled) ==
                LxrLargeObjectResult::Success,
            "recycled allocation");
        Check(recycled.page_start == first.page_start, "recycled address");
        Check(
            reinterpret_cast<uint8_t*>(recycled.object)[0] == 0 &&
                reinterpret_cast<uint8_t*>(recycled.object)[recycled.object_bytes - 1] == 0,
            "recycled allocation zero");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectPageReuse, recycled.page_start) == 0,
            "reuse wraps");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectPageReuse, neighboringPage) == 17,
            "neighboring reuse unchanged");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectMarkNursery, recycled.object) ==
                (LxrLargeObjectSpace::MarkBit | LxrLargeObjectSpace::NurseryBit),
            "concurrent nursery marked");

        bool updated;
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LxrLargeObjectResult::InvalidPhase,
            "promotion phase restriction");
        Check(space.BeginRelease() == LxrLargeObjectResult::Success, "begin release");
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LxrLargeObjectResult::Success &&
                updated,
            "mark and promote");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectMarkNursery, recycled.object) ==
                LxrLargeObjectSpace::MarkBit,
            "promoted state");
        Check(
            Load(metadata, LxrSideMetadataKind::FieldUnlogged, recycled.object) == 1,
            "promotion initializes field log");
        Check(
            space.TryMarkAndPromote(recycled.object, Owner, &updated) ==
                LxrLargeObjectResult::Success &&
                !updated,
            "mark and promote idempotent");
        Check(
            space.TryRelease(recycled.object, Owner) == LxrLargeObjectResult::Success,
            "release recycled");
        Check(space.EndCollection() == LxrLargeObjectResult::Success, "end collection");

        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectMarkNursery, recycled.object) == 0,
            "release clears mark nursery");
        Check(
            Load(metadata, LxrSideMetadataKind::ValidObject, recycled.object) == 0,
            "release clears valid object");
        Check(
            Load(metadata, LxrSideMetadataKind::LargeObjectPageReuse, recycled.page_start) == 0,
            "release preserves reuse");

        LxrLargeObjectAllocation thresholdPlusOne;
        Check(
            space.Allocate(32769, 8, 0, Owner, &thresholdPlusOne) ==
                LxrLargeObjectResult::Success,
            "threshold plus one allocation");
        Check(thresholdPlusOne.object_bytes == 32769, "threshold plus one logical size");
        Check(thresholdPlusOne.page_count == 9, "threshold plus one page span");
        Check(
            Load(
                metadata,
                LxrSideMetadataKind::LargeObjectMarkNursery,
                thresholdPlusOne.object) ==
                (LxrLargeObjectSpace::MarkBit | LxrLargeObjectSpace::NurseryBit),
            "threshold plus one nursery state");
        Check(
            space.BeginCollection(false, false) == LxrLargeObjectResult::Success,
            "threshold plus one begin release");
        Check(
            space.TryMarkAndPromote(thresholdPlusOne.object, Owner, &updated) ==
                LxrLargeObjectResult::Success &&
                updated,
            "threshold plus one promote");
        Check(
            Load(
                metadata,
                LxrSideMetadataKind::FieldUnlogged,
                thresholdPlusOne.object) == 1,
            "threshold plus one first field log");
        Check(
            Load(
                metadata,
                LxrSideMetadataKind::FieldUnlogged,
                thresholdPlusOne.object + 32768) == 1,
            "threshold plus one rounded field log");
        Check(
            Load(
                metadata,
                LxrSideMetadataKind::LargeObjectMarkNursery,
                thresholdPlusOne.object) == LxrLargeObjectSpace::MarkBit,
            "threshold plus one promoted state");
        Check(
            space.TryRelease(thresholdPlusOne.object, Owner) ==
                LxrLargeObjectResult::Success,
            "threshold plus one release");
        Check(
            space.EndCollection() == LxrLargeObjectResult::Success,
            "threshold plus one end collection");

        space.Shutdown();
        RunLookupChecks(metadata);
        RunFreeSpanChecks(metadata);
        RunRandomChecks(metadata);
        RunFailureChecks(metadata);
        RunGrowthChecks(metadata);
        RunConcurrentChecks(metadata);
        metadata.Shutdown();
    }

    std::printf("%d/%d large object space checks passed\n", s_checks - s_failures, s_checks);
    return s_failures == 0 ? 0 : 1;
#endif
}
