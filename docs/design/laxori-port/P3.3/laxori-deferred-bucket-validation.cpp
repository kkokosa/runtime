// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc_laxori/laxori_work_packet.h"
#include "../../../../src/coreclr/gc_laxori/laxori_work_scheduler.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace
{
    constexpr uint32_t TimeoutMilliseconds = 30'000;

    int s_checks;
    int s_passed;

    bool Check(bool condition, const char* name)
    {
        s_checks++;
        if (!condition)
        {
            std::printf("FAIL: %s\n", name);
            return false;
        }
        s_passed++;
        return true;
    }

    struct ExecutionState
    {
        std::mutex lock;
        std::vector<uint64_t> order;
        std::atomic<uint64_t> executions{0};
        std::atomic<uint64_t> checksum{0};
        std::atomic<bool> block{false};
        std::atomic<bool> started{false};
    };

    void ExecutePacket(LaxoriWorkPacket* packet, size_t workerIndex, void* context)
    {
        ExecutionState* state = static_cast<ExecutionState*>(context);
        uint64_t checksum = packet->GetId() ^ workerIndex;
        for (size_t index = 0; index < packet->GetReferenceCount(); index++)
        {
            checksum = (checksum * UINT64_C(1'099'511'628'211)) ^
                packet->GetReferences()[index];
        }
        state->checksum.fetch_xor(checksum, std::memory_order_relaxed);
        state->executions.fetch_add(1, std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> guard(state->lock);
            state->order.push_back(packet->GetId());
        }

        if (state->block.load(std::memory_order_acquire))
        {
            state->started.store(true, std::memory_order_release);
            while (state->block.load(std::memory_order_acquire))
            {
                std::this_thread::yield();
            }
        }
    }

    bool WaitUntil(const std::atomic<bool>& value)
    {
        std::chrono::steady_clock::time_point deadline =
            std::chrono::steady_clock::now() +
            std::chrono::milliseconds(TimeoutMilliseconds);
        while (!value.load(std::memory_order_acquire))
        {
            if (std::chrono::steady_clock::now() >= deadline)
            {
                return false;
            }
            std::this_thread::yield();
        }
        return true;
    }

    std::unique_ptr<LaxoriWorkPacket> NewPacket(
        uint64_t id,
        LaxoriWorkBucketStage stage,
        const std::vector<uintptr_t>& references,
        ExecutionState* state)
    {
        return std::make_unique<LaxoriWorkPacket>(
            id,
            stage,
            references.data(),
            references.size(),
            ExecutePacket,
            state);
    }

    bool FinishAndPublish(
        LaxoriWorkScheduler& scheduler,
        uint64_t generation,
        bool expectWork)
    {
        bool success = true;
        success &= Check(
            scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "cycle completes");
        success &= Check(
            scheduler.PublishDeferredConcurrentWork(generation) ==
                LaxoriWorkSchedulerResult::InvalidState,
            "publication before resume rejected");
        success &= Check(
            scheduler.ResumeConcurrentWork() == LaxoriWorkSchedulerResult::Success,
            "concurrent work resume recorded");
        success &= Check(
            scheduler.PublishDeferredConcurrentWork(generation) ==
                LaxoriWorkSchedulerResult::Success,
            "deferred work published");
        success &= Check(
            scheduler.PublishDeferredConcurrentWork(generation) ==
                LaxoriWorkSchedulerResult::InvalidState,
            "duplicate publication rejected");
        LaxoriDeferredWorkState state = scheduler.GetDeferredWorkState();
        success &= Check(
            state.publishedGeneration == generation &&
                state.sealedIndex == LaxoriNoDeferredQueue,
            "publication state records generation");
        success &= Check(
            (state.activeIndex != LaxoriNoDeferredQueue) == true,
            "publication selects an active side");
        if (!expectWork)
        {
            success &= Check(
                scheduler.GetMetrics().deferredEmptyFlips > 0,
                "empty publication recorded");
        }
        return success;
    }

    bool ValidateDisabledAndInvalidInputs()
    {
        LaxoriWorkScheduler scheduler;
        bool success = Check(
            scheduler.Initialize(1) == LaxoriWorkSchedulerResult::Success,
            "disabled scheduler initialize");
        std::vector<uintptr_t> references(4, 11);
        ExecutionState state;
        std::unique_ptr<LaxoriWorkPacket> packet = NewPacket(
            1,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        success &= Check(
            scheduler.SubmitDeferredConcurrent(
                packet.get(),
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::InvalidState,
            "disabled deferred submission rejected");
        success &= Check(
            scheduler.PublishDeferredConcurrentWork(1) ==
                LaxoriWorkSchedulerResult::InvalidState,
            "disabled publication rejected");
        success &= Check(
            !scheduler.GetDeferredWorkState().enabled,
            "disabled state reported");
        scheduler.Shutdown();

        LaxoriWorkScheduler enabled;
        success &= Check(
            enabled.Initialize(1, true) == LaxoriWorkSchedulerResult::Success,
            "enabled scheduler initialize");
        std::unique_ptr<LaxoriWorkPacket> invalidStage = NewPacket(
            2,
            LaxoriWorkBucketStage::Initial,
            references,
            &state);
        success &= Check(
            enabled.SubmitDeferredConcurrent(
                invalidStage.get(),
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::InvalidStage,
            "deferred work requires unconstrained stage");
        success &= Check(
            enabled.SubmitDeferredConcurrent(
                packet.get(),
                static_cast<LaxoriDeferredWorkPriority>(99)) ==
                LaxoriWorkSchedulerResult::InvalidArgument,
            "invalid deferred priority rejected");
        enabled.Shutdown();
        return success;
    }

    bool ValidateDirectionVisibilityAndGenerations()
    {
        LaxoriWorkScheduler scheduler;
        if (!Check(
            scheduler.Initialize(1, true) == LaxoriWorkSchedulerResult::Success,
            "direction scheduler initialize"))
        {
            return false;
        }

        bool success = true;
        ExecutionState state;
        std::vector<uintptr_t> references(32, 0x1234);
        std::unique_ptr<LaxoriWorkPacket> normal = NewPacket(
            10,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        std::unique_ptr<LaxoriWorkPacket> prioritized = NewPacket(
            11,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        success &= Check(
            scheduler.SubmitDeferredConcurrent(
                normal.get(),
                LaxoriDeferredWorkPriority::Normal,
                0) == LaxoriWorkSchedulerResult::Success,
            "normal packet enters producer side");
        success &= Check(
            scheduler.SubmitDeferredConcurrent(
                prioritized.get(),
                LaxoriDeferredWorkPriority::Prioritized,
                0) == LaxoriWorkSchedulerResult::Success,
            "prioritized packet enters producer side");
        LaxoriDeferredWorkState before = scheduler.GetDeferredWorkState();
        success &= Check(
            before.activeIndex == 0 &&
                before.producerIndex == 1 &&
                before.producerGeneration == 1 &&
                before.pendingNormal == 1 &&
                before.pendingPrioritized == 1,
            "initial active and producer directions");
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        success &= Check(
            state.executions.load(std::memory_order_relaxed) == 0,
            "producer side invisible before cycle");
        success &= Check(
            scheduler.GetStageOutstanding(LaxoriWorkBucketStage::Unconstrained) == 0,
            "producer side excluded from active outstanding count");

        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "first cycle begins");
        success &= Check(
            scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "first cycle completes");
        LaxoriDeferredWorkState sealed = scheduler.GetDeferredWorkState();
        success &= Check(
            sealed.activeIndex == LaxoriNoDeferredQueue &&
                sealed.sealedIndex == 1 &&
                sealed.producerIndex == 0 &&
                sealed.sealedGeneration == 1 &&
                sealed.producerGeneration == 2 &&
                sealed.sealedNormal == 1 &&
                sealed.sealedPrioritized == 1,
            "cycle completion seals and reverses direction");
        success &= Check(
            state.executions.load(std::memory_order_relaxed) == 0,
            "sealed side invisible before publication");

        std::unique_ptr<LaxoriWorkPacket> nextGeneration = NewPacket(
            12,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        success &= Check(
            scheduler.SubmitDeferredConcurrent(
                nextGeneration.get(),
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::Success,
            "post-seal producer binds next generation");
        success &= Check(
            nextGeneration->GetGeneration() == 2,
            "post-seal packet generation");

        success &= Check(
            scheduler.ResetCompletedCycle() ==
                LaxoriWorkSchedulerResult::InvalidState,
            "reset before publication rejected");
        success &= FinishAndPublish(scheduler, 1, true);
        success &= Check(
            scheduler.GetStageOutstanding(LaxoriWorkBucketStage::Unconstrained) == 2,
            "publication accounts active packets");
        success &= Check(
            scheduler.WaitForPacket(prioritized.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForPacket(normal.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "published packets execute");
        success &= Check(
            state.executions.load(std::memory_order_relaxed) == 2,
            "next generation remains invisible");
        {
            std::lock_guard<std::mutex> guard(state.lock);
            success &= Check(
                state.order.size() >= 2 &&
                    state.order[0] == 11 &&
                    state.order[1] == 10,
                "prioritized lane executes before normal lane");
        }
        success &= Check(
            scheduler.WaitForIdle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "published first generation drains");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "first generation resets after drain");

        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "second cycle begins");
        success &= FinishAndPublish(scheduler, 2, true);
        success &= Check(
            scheduler.WaitForPacket(nextGeneration.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "next generation visible after its flip");
        success &= Check(
            state.executions.load(std::memory_order_relaxed) == 3,
            "no loss or duplication across direction reversal");
        success &= Check(
            scheduler.WaitForIdle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                scheduler.ResetCompletedCycle() ==
                    LaxoriWorkSchedulerResult::Success,
            "second generation drains and resets");

        LaxoriWorkSchedulerMetrics metrics = scheduler.GetMetrics();
        success &= Check(
            metrics.deferredSubmitted == 3 &&
                metrics.deferredPublished == 3 &&
                metrics.deferredExecuted == 3 &&
                metrics.deferredFlips == 2 &&
                metrics.deferredEmptyFlips == 0 &&
                metrics.ownershipViolations == 0,
            "deferred metrics exact across repeated cycles");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateEmptyAndEagerCycles()
    {
        LaxoriWorkScheduler scheduler;
        if (!Check(
            scheduler.Initialize(2, true) == LaxoriWorkSchedulerResult::Success,
            "empty scheduler initialize"))
        {
            return false;
        }

        bool success = Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "empty cycle begins");
        success &= FinishAndPublish(scheduler, 1, false);
        LaxoriDeferredWorkState state = scheduler.GetDeferredWorkState();
        success &= Check(
            state.activeIndex == 1 &&
                state.producerIndex == 0 &&
                state.producerGeneration == 2,
            "empty flip still reverses direction");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "empty cycle resets");

        ExecutionState execution;
        std::vector<uintptr_t> references(16, 9);
        std::unique_ptr<LaxoriWorkPacket> eager = NewPacket(
            20,
            LaxoriRCProcessDecs,
            references,
            &execution);
        success &= Check(
            scheduler.Submit(eager.get()) == LaxoriWorkSchedulerResult::Success,
            "lazy-off decrement enters STW bucket");
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "eager cycle begins");
        success &= Check(
            scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "eager cycle completes");
        success &= Check(
            execution.executions.load(std::memory_order_relaxed) == 1 &&
                eager->GetState() == LaxoriWorkPacketState::Completed,
            "lazy-off decrement executes during pause");
        success &= Check(
            scheduler.GetDeferredWorkState().sealedNormal == 0 &&
                scheduler.GetDeferredWorkState().sealedPrioritized == 0,
            "lazy-off cycle seals no deferred packets");
        success &= Check(
            scheduler.ResumeConcurrentWork() == LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(2) ==
                    LaxoriWorkSchedulerResult::Success,
            "lazy-off cycle performs explicit empty flip");
        success &= Check(
            scheduler.GetMetrics().deferredEmptyFlips == 2,
            "both empty flips recorded");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "eager cycle resets");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateProducerRaces()
    {
        LaxoriWorkScheduler scheduler;
        if (!Check(
            scheduler.Initialize(2, true) == LaxoriWorkSchedulerResult::Success,
            "race scheduler initialize"))
        {
            return false;
        }

        bool success = true;
        ExecutionState blocking;
        blocking.block.store(true, std::memory_order_release);
        ExecutionState deferred;
        std::vector<uintptr_t> references(8, 7);
        std::unique_ptr<LaxoriWorkPacket> blocker = NewPacket(
            30,
            LaxoriWorkBucketStage::Initial,
            references,
            &blocking);
        std::unique_ptr<LaxoriWorkPacket> beforeSeal = NewPacket(
            31,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &deferred);
        success &= Check(
            scheduler.Submit(blocker.get()) == LaxoriWorkSchedulerResult::Success,
            "blocking STW packet queued");
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "race cycle begins");
        success &= Check(WaitUntil(blocking.started), "blocking packet starts");
        success &= Check(
            scheduler.SubmitDeferredConcurrent(
                beforeSeal.get(),
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::Success &&
                beforeSeal->GetGeneration() == 1,
            "producer before seal binds current generation");
        blocking.block.store(false, std::memory_order_release);
        success &= Check(
            scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "race cycle completes after release");

        std::unique_ptr<LaxoriWorkPacket> afterSeal = NewPacket(
            32,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &deferred);
        std::thread producer([&]()
        {
            LaxoriWorkSchedulerResult result = scheduler.SubmitDeferredConcurrent(
                afterSeal.get(),
                LaxoriDeferredWorkPriority::Normal);
            if (result != LaxoriWorkSchedulerResult::Success)
            {
                deferred.checksum.store(UINT64_MAX, std::memory_order_release);
            }
        });
        producer.join();
        success &= Check(
            afterSeal->GetGeneration() == 2 &&
                deferred.checksum.load(std::memory_order_acquire) != UINT64_MAX,
            "producer after seal binds next generation");
        success &= Check(
            scheduler.ResumeConcurrentWork() == LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(1) ==
                    LaxoriWorkSchedulerResult::Success,
            "race generation publishes");
        success &= Check(
            scheduler.WaitForPacket(beforeSeal.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "pre-seal packet published");
        success &= Check(
            deferred.executions.load(std::memory_order_relaxed) == 1 &&
                afterSeal->GetState() == LaxoriWorkPacketState::Queued,
            "post-seal packet remains inactive");
        success &= Check(
            scheduler.WaitForIdle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                scheduler.ResetCompletedCycle() ==
                    LaxoriWorkSchedulerResult::Success,
            "race generation drains");
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "post-race generation begins");
        success &= FinishAndPublish(scheduler, 2, true);
        success &= Check(
            scheduler.WaitForPacket(afterSeal.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                deferred.executions.load(std::memory_order_relaxed) == 2,
            "post-seal packet publishes in next cycle");
        success &= Check(
            scheduler.WaitForIdle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                scheduler.ResetCompletedCycle() ==
                    LaxoriWorkSchedulerResult::Success,
            "post-race generation resets");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateStealingAndBusyRecovery()
    {
        LaxoriWorkScheduler scheduler;
        if (!Check(
            scheduler.Initialize(8, true) == LaxoriWorkSchedulerResult::Success,
            "stealing scheduler initialize"))
        {
            return false;
        }

        bool success = true;
        ExecutionState state;
        state.block.store(true, std::memory_order_release);
        std::vector<uintptr_t> references(64, 17);
        std::vector<std::unique_ptr<LaxoriWorkPacket>> packets;
        for (uint64_t id = 64; id < 192; id++)
        {
            packets.push_back(NewPacket(
                id,
                LaxoriWorkBucketStage::Unconstrained,
                references,
                &state));
            success &= Check(
                scheduler.SubmitDeferredConcurrent(
                    packets.back().get(),
                    LaxoriDeferredWorkPriority::Normal,
                    0) == LaxoriWorkSchedulerResult::Success,
                "skewed deferred packet queued");
        }
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success,
            "stealing cycle begins");
        success &= Check(
            scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success &&
                scheduler.ResumeConcurrentWork() ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(1) ==
                    LaxoriWorkSchedulerResult::Success,
            "skewed deferred packets publish");
        success &= Check(WaitUntil(state.started), "published work begins");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Busy,
            "reset fails busy while published work executes");
        state.block.store(false, std::memory_order_release);
        success &= Check(
            scheduler.WaitForIdle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "skewed work drains");
        for (const std::unique_ptr<LaxoriWorkPacket>& packet : packets)
        {
            success &= Check(
                packet->GetState() == LaxoriWorkPacketState::Completed,
                "skewed packet executes exactly once");
        }
        LaxoriWorkSchedulerMetrics metrics = scheduler.GetMetrics();
        success &= Check(metrics.stolen > 0, "published work can be stolen");
        success &= Check(
            metrics.deferredExecuted == packets.size() &&
                metrics.ownershipViolations == 0,
            "published active side has exact ownership");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "busy reset recovers after drain");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateShutdownOwnership()
    {
        bool success = true;
        std::vector<uintptr_t> references(4, 3);
        ExecutionState state;

        LaxoriWorkScheduler producerScheduler;
        success &= Check(
            producerScheduler.Initialize(1, true) ==
                LaxoriWorkSchedulerResult::Success,
            "producer shutdown scheduler initialize");
        std::unique_ptr<LaxoriWorkPacket> producer = NewPacket(
            200,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        success &= Check(
            producerScheduler.SubmitDeferredConcurrent(
                producer.get(),
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::Success,
            "producer packet queued for shutdown");
        producerScheduler.Shutdown();
        success &= Check(
            producer->GetState() == LaxoriWorkPacketState::CallerOwned &&
                producer->GetGeneration() == 0,
            "shutdown returns producer-side ownership");

        LaxoriWorkScheduler sealedScheduler;
        success &= Check(
            sealedScheduler.Initialize(1, true) ==
                LaxoriWorkSchedulerResult::Success,
            "sealed shutdown scheduler initialize");
        std::unique_ptr<LaxoriWorkPacket> sealed = NewPacket(
            201,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            &state);
        success &= Check(
            sealedScheduler.SubmitDeferredConcurrent(
                sealed.get(),
                LaxoriDeferredWorkPriority::Prioritized) ==
                LaxoriWorkSchedulerResult::Success &&
                sealedScheduler.BeginStwCycle() ==
                    LaxoriWorkSchedulerResult::Success &&
                sealedScheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success,
            "packet reaches sealed side");
        sealedScheduler.Shutdown();
        success &= Check(
            sealed->GetState() == LaxoriWorkPacketState::CallerOwned &&
                sealed->GetGeneration() == 0,
            "shutdown returns sealed-side ownership");
        return success;
    }
}

int main()
{
    bool success = true;
    success &= ValidateDisabledAndInvalidInputs();
    success &= ValidateDirectionVisibilityAndGenerations();
    success &= ValidateEmptyAndEagerCycles();
    success &= ValidateProducerRaces();
    success &= ValidateStealingAndBusyRecovery();
    success &= ValidateShutdownOwnership();

    if (!success || s_passed != s_checks)
    {
        std::printf("FAIL: %d/%d P3.3 validation checks passed\n", s_passed, s_checks);
        return 1;
    }

    std::printf("PASS: %d/%d P3.3 validation checks\n", s_passed, s_checks);
    return 0;
}
