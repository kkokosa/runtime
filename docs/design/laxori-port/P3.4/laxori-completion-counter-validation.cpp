// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc_laxori/laxori_completion_counter.h"
#include "../../../../src/coreclr/gc_laxori/laxori_work_packet.h"
#include "../../../../src/coreclr/gc_laxori/laxori_work_scheduler.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
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

    struct DirectContext
    {
        LaxoriLazyCompletionRegistration sweep;
        std::atomic<uint32_t> order{0};
        std::atomic<uint32_t> decrementOrder{0};
        std::atomic<uint32_t> overallOrder{0};
        std::atomic<uint32_t> decrementCallbacks{0};
        std::atomic<uint32_t> overallCallbacks{0};
        bool failDecrement = false;
        bool failOverall = false;
    };

    LaxoriCompletionCallbackResult DirectDecrementsDrained(
        LaxoriMatureSweepContinuation* continuation,
        void* context)
    {
        DirectContext* state = static_cast<DirectContext*>(context);
        state->decrementCallbacks.fetch_add(1, std::memory_order_seq_cst);
        state->decrementOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
        if (state->failDecrement)
        {
            return LaxoriCompletionCallbackResult::Failure;
        }
        return continuation->RegisterSweep(&state->sweep) ==
            LaxoriCompletionResult::Success
            ? LaxoriCompletionCallbackResult::Success
            : LaxoriCompletionCallbackResult::Failure;
    }

    LaxoriCompletionCallbackResult DirectOverallDrained(uint64_t, void* context)
    {
        DirectContext* state = static_cast<DirectContext*>(context);
        state->overallCallbacks.fetch_add(1, std::memory_order_seq_cst);
        state->overallOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
        return state->failOverall
            ? LaxoriCompletionCallbackResult::Failure
            : LaxoriCompletionCallbackResult::Success;
    }

    bool ValidateDirectCounter()
    {
        DirectContext context;
        LaxoriLazyCompletionGenerationState state;
        LaxoriLazyCompletionRegistration seed;
        bool success = Check(
            state.Initialize(
                7,
                DirectDecrementsDrained,
                DirectOverallDrained,
                &context,
                &seed) == LaxoriCompletionResult::Success,
            "direct generation initializes");
        LaxoriLazyCompletionRegistration decrement;
        LaxoriLazyCompletionRegistration overall;
        success &= Check(
            state.RegisterRoot(
                7,
                LaxoriCompletionWorkKind::Decrement,
                &decrement) == LaxoriCompletionResult::Success,
            "decrement root registers");
        success &= Check(
            state.RegisterRoot(
                7,
                LaxoriCompletionWorkKind::Overall,
                &overall) == LaxoriCompletionResult::Success,
            "overall root registers");
        LaxoriLazyCompletionRegistration forgedSweep;
        success &= Check(
            state.RegisterRoot(
                7,
                LaxoriCompletionWorkKind::MatureSweep,
                &forgedSweep) == LaxoriCompletionResult::InvalidArgument,
            "mature sweep cannot be forged as root work");
        LaxoriCompletionSnapshot initial = state.GetSnapshot();
        success &= Check(
            initial.overallOutstanding == 3 &&
                initial.decrementOutstanding == 2,
            "initial counter balance");
        LaxoriBlockReleaseGuard earlyGuard;
        success &= Check(
            decrement.CreateReleaseGuard(&earlyGuard) ==
                LaxoriCompletionResult::InvalidState &&
                !earlyGuard.IsValid(),
            "release guard denied before decrement zero");
        success &= Check(
            decrement.Complete() == LaxoriCompletionResult::Success &&
                context.decrementCallbacks.load(std::memory_order_seq_cst) == 0,
            "non-last decrement completes without callback");
        success &= Check(
            overall.Complete() == LaxoriCompletionResult::Success,
            "overall-only work completes");
        success &= Check(
            state.Seal(7) == LaxoriCompletionResult::Success &&
                state.MarkPublished(7) == LaxoriCompletionResult::Success,
            "generation seals and publishes");
        success &= Check(
            seed.Complete() == LaxoriCompletionResult::Success,
            "seed completes");
        LaxoriCompletionSnapshot afterDecrements = state.GetSnapshot();
        success &= Check(
            afterDecrements.decrementOutstanding == 0 &&
                afterDecrements.overallOutstanding == 1 &&
                afterDecrements.decrementZeroTransitions == 1 &&
                afterDecrements.overallZeroTransitions == 0,
            "decrement zero schedules overall-counted sweep");
        success &= Check(
            context.decrementOrder.load(std::memory_order_seq_cst) == 1 &&
                context.overallCallbacks.load(std::memory_order_seq_cst) == 0,
            "decrement callback precedes overall callback");
        LaxoriBlockReleaseGuard guard;
        success &= Check(
            context.sweep.CreateReleaseGuard(&guard) ==
                LaxoriCompletionResult::Success &&
                guard.IsValid() &&
                guard.GetGeneration() == 7,
            "mature sweep owns release guard");
        success &= Check(
            context.sweep.Complete() == LaxoriCompletionResult::Success,
            "mature sweep completes");
        LaxoriCompletionSnapshot drained = state.GetSnapshot();
        success &= Check(
            drained.overallOutstanding == 0 &&
                drained.decrementOutstanding == 0 &&
                drained.decrementZeroTransitions == 1 &&
                drained.overallZeroTransitions == 1 &&
                drained.decrementCallbacks == 1 &&
                drained.overallCallbacks == 1 &&
                drained.lifecycle == LaxoriCompletionLifecycle::Drained,
            "direct generation drains exactly once");
        success &= Check(
            context.overallOrder.load(std::memory_order_seq_cst) == 2,
            "overall callback follows sweep");
        success &= Check(
            seed.Complete() == LaxoriCompletionResult::AlreadyCompleted &&
                context.sweep.Complete() ==
                    LaxoriCompletionResult::AlreadyCompleted,
            "double completion rejected");
        success &= Check(
            state.PrepareForReuse(6) ==
                    LaxoriCompletionResult::StaleGeneration &&
                state.PrepareForReuse(7) == LaxoriCompletionResult::Success,
            "state reuse requires exact drained generation");
        success &= Check(
            !guard.IsValid(),
            "old release guard invalid after state reset");

        LaxoriLazyCompletionRegistration secondSeed;
        success &= Check(
            state.Initialize(
                8,
                DirectDecrementsDrained,
                DirectOverallDrained,
                &context,
                &secondSeed) == LaxoriCompletionResult::Success,
            "embedded state reinitializes after drain");
        success &= Check(
            state.RegisterRoot(
                7,
                LaxoriCompletionWorkKind::Decrement,
                &decrement) == LaxoriCompletionResult::StaleGeneration,
            "stale root registration rejected");
        success &= Check(
            state.Cancel(8) == LaxoriCompletionResult::Success &&
                secondSeed.Complete() == LaxoriCompletionResult::Cancelled &&
                state.FinalizeCancellation(8) ==
                    LaxoriCompletionResult::Success,
            "cancelled generation drains without callbacks");
        return success;
    }

    bool ValidateOverflowAndFailure()
    {
        bool success = true;
        DirectContext overflowContext;
        LaxoriLazyCompletionGenerationState overflowState;
        LaxoriLazyCompletionRegistration overflowSeed;
        success &= Check(
            overflowState.Initialize(
                11,
                DirectDecrementsDrained,
                DirectOverallDrained,
                &overflowContext,
                &overflowSeed,
                1) == LaxoriCompletionResult::Success,
            "bounded counter initializes");
        LaxoriLazyCompletionRegistration overflow;
        success &= Check(
            overflowState.RegisterRoot(
                11,
                LaxoriCompletionWorkKind::Decrement,
                &overflow) == LaxoriCompletionResult::Overflow,
            "counter overflow rejected");
        success &= Check(
            overflowState.Cancel(11) == LaxoriCompletionResult::Success &&
                overflowSeed.Complete() == LaxoriCompletionResult::Cancelled &&
                overflowState.GetSnapshot().overallOutstanding == 0,
            "overflow leaves balanced seed");

        DirectContext failureContext;
        failureContext.failDecrement = true;
        LaxoriLazyCompletionGenerationState failureState;
        LaxoriLazyCompletionRegistration failureSeed;
        success &= Check(
            failureState.Initialize(
                12,
                DirectDecrementsDrained,
                DirectOverallDrained,
                &failureContext,
                &failureSeed) == LaxoriCompletionResult::Success &&
                failureState.Seal(12) == LaxoriCompletionResult::Success &&
                failureState.MarkPublished(12) ==
                    LaxoriCompletionResult::Success,
            "failure generation publishes");
        success &= Check(
            failureSeed.Complete() == LaxoriCompletionResult::CallbackFailed,
            "decrement callback failure propagates");
        LaxoriCompletionSnapshot failed = failureState.GetSnapshot();
        success &= Check(
            failed.lifecycle == LaxoriCompletionLifecycle::Failed &&
                failed.overallOutstanding == 0 &&
                failed.decrementOutstanding == 0 &&
                failed.decrementCallbacks == 1 &&
                failed.overallCallbacks == 0,
            "failure suppresses successful next decision");
        success &= Check(
            failureState.PrepareForReuse(12) ==
                LaxoriCompletionResult::InvalidState,
            "failed generation cannot be reused as success");
        return success;
    }

    struct SchedulerContext
    {
        LaxoriWorkScheduler* scheduler = nullptr;
        LaxoriWorkPacket* child = nullptr;
        LaxoriWorkPacket* sweep = nullptr;
        std::atomic<bool> childStarted{false};
        std::atomic<bool> releaseChild{false};
        std::atomic<uint32_t> order{0};
        std::atomic<uint32_t> promotionOrder{0};
        std::atomic<uint32_t> decrementOrder{0};
        std::atomic<uint32_t> sweepOrder{0};
        std::atomic<uint32_t> overallOrder{0};
        std::atomic<uint32_t> releases{0};
        std::atomic<uint32_t> reentrantQueries{0};
        bool scheduleSweep = true;
    };

    void ExecuteChild(LaxoriWorkPacket*, size_t, void* context)
    {
        SchedulerContext* state = static_cast<SchedulerContext*>(context);
        state->childStarted.store(true, std::memory_order_release);
        while (!state->releaseChild.load(std::memory_order_acquire))
        {
            std::this_thread::yield();
        }
        state->promotionOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
    }

    void ExecuteParent(LaxoriWorkPacket* packet, size_t, void* context)
    {
        SchedulerContext* state = static_cast<SchedulerContext*>(context);
        if (state->scheduler->SubmitTrackedChild(
                packet,
                state->child,
                LaxoriCompletionWorkKind::Decrement) !=
            LaxoriWorkSchedulerResult::Success)
        {
            state->releases.store(UINT32_MAX, std::memory_order_release);
        }
    }

    void ExecuteSweep(LaxoriWorkPacket* packet, size_t, void* context)
    {
        SchedulerContext* state = static_cast<SchedulerContext*>(context);
        LaxoriBlockReleaseGuard guard;
        if (packet->CreateBlockReleaseGuard(&guard) !=
                LaxoriCompletionResult::Success ||
            !guard.IsValid())
        {
            state->releases.store(UINT32_MAX, std::memory_order_release);
            return;
        }
        state->sweepOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
        state->releases.fetch_add(1, std::memory_order_seq_cst);
    }

    LaxoriCompletionCallbackResult SchedulerDecrementsDrained(
        LaxoriMatureSweepContinuation* continuation,
        void* context)
    {
        SchedulerContext* state = static_cast<SchedulerContext*>(context);
        state->decrementOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
        LaxoriCompletionSnapshot snapshot{};
        if (state->scheduler->GetCompletionSnapshot(
                continuation->GetGeneration(),
                &snapshot) == LaxoriWorkSchedulerResult::Success)
        {
            state->reentrantQueries.fetch_add(1, std::memory_order_seq_cst);
        }
        if (!state->scheduleSweep)
        {
            return LaxoriCompletionCallbackResult::Success;
        }
        return state->scheduler->SubmitMatureSweep(
                   continuation,
                   state->sweep) == LaxoriWorkSchedulerResult::Success
            ? LaxoriCompletionCallbackResult::Success
            : LaxoriCompletionCallbackResult::Failure;
    }

    LaxoriCompletionCallbackResult SchedulerOverallDrained(
        uint64_t generation,
        void* context)
    {
        SchedulerContext* state = static_cast<SchedulerContext*>(context);
        LaxoriCompletionSnapshot snapshot{};
        if (state->scheduler->GetCompletionSnapshot(generation, &snapshot) ==
            LaxoriWorkSchedulerResult::Success)
        {
            state->reentrantQueries.fetch_add(1, std::memory_order_seq_cst);
        }
        state->overallOrder.store(
            state->order.fetch_add(1, std::memory_order_seq_cst) + 1,
            std::memory_order_seq_cst);
        return LaxoriCompletionCallbackResult::Success;
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

    bool ValidateSchedulerIntegration()
    {
        bool success = true;
        uintptr_t references[] = {1, 2, 3, 4};
        LaxoriWorkScheduler scheduler;
        SchedulerContext context;
        context.scheduler = &scheduler;
        LaxoriWorkPacket child(
            2,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            4,
            ExecuteChild,
            &context);
        LaxoriWorkPacket sweep(
            3,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            4,
            ExecuteSweep,
            &context);
        context.child = &child;
        context.sweep = &sweep;
        success &= Check(
            scheduler.Initialize(
                3,
                true,
                true,
                SchedulerDecrementsDrained,
                SchedulerOverallDrained,
                &context) == LaxoriWorkSchedulerResult::Success,
            "tracked scheduler initializes");
        LaxoriWorkPacket parent(
            1,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            4,
            ExecuteParent,
            &context);
        success &= Check(
            scheduler.SubmitDeferredConcurrentTracked(
                &parent,
                LaxoriCompletionWorkKind::Decrement,
                LaxoriDeferredWorkPriority::Prioritized) ==
                LaxoriWorkSchedulerResult::Success,
            "tracked deferred root submits");
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.ResumeConcurrentWork() ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(1) ==
                    LaxoriWorkSchedulerResult::Success,
            "tracked generation publishes after resume");
        success &= Check(WaitUntil(context.childStarted), "child work starts");
        // The parent registers the child inside its own Execute, and its own registration ends after Execute returns. The
        // child can start on another worker before that, so the snapshot is taken only when the parent has completed.
        success &= Check(
            scheduler.WaitForPacket(&parent, TimeoutMilliseconds) == LaxoriWorkSchedulerResult::Success,
            "parent completes while the child still runs");
        LaxoriCompletionSnapshot blocked{};
        success &= Check(
            scheduler.GetCompletionSnapshot(1, &blocked) ==
                    LaxoriWorkSchedulerResult::Success &&
                blocked.decrementOutstanding == 1 &&
                blocked.overallOutstanding == 1 &&
                blocked.decrementZeroTransitions == 0 &&
                context.releases.load(std::memory_order_acquire) == 0,
            "child registration blocks decrement zero and release");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Busy,
            "cycle reset blocked by lazy work");
        context.releaseChild.store(true, std::memory_order_release);
        success &= Check(
            scheduler.WaitForPacket(&parent, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForPacket(&child, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForPacket(&sweep, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCompletion(1, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForIdle(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success,
            "child sweep and decision drain");
        LaxoriCompletionSnapshot drained{};
        success &= Check(
            scheduler.GetCompletionSnapshot(1, &drained) ==
                    LaxoriWorkSchedulerResult::Success &&
                drained.overallOutstanding == 0 &&
                drained.decrementOutstanding == 0 &&
                drained.decrementZeroTransitions == 1 &&
                drained.overallZeroTransitions == 1 &&
                drained.ownershipViolations == 0,
            "scheduler counter drains exactly once");
        success &= Check(
            context.promotionOrder.load(std::memory_order_seq_cst) == 1 &&
                context.decrementOrder.load(std::memory_order_seq_cst) == 2 &&
                context.sweepOrder.load(std::memory_order_seq_cst) == 3 &&
                context.overallOrder.load(std::memory_order_seq_cst) == 4 &&
                context.releases.load(std::memory_order_seq_cst) == 1,
            "promotion precedes release and decision");
        success &= Check(
            context.reentrantQueries.load(std::memory_order_seq_cst) == 2,
            "zero callbacks execute outside scheduler lock");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "drained generation resets");

        context.scheduleSweep = false;
        success &= Check(
            scheduler.BeginStwCycle() == LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.ResumeConcurrentWork() ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(2) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCompletion(2, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success,
            "empty second generation drains");
        success &= Check(
            scheduler.GetCompletionSnapshot(1, &drained) ==
                LaxoriWorkSchedulerResult::StaleGeneration,
            "reused embedded side rejects stale generation");
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success,
            "second generation resets");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateDisabledAndShutdown()
    {
        uintptr_t references[] = {9};
        bool success = true;
        LaxoriWorkScheduler disabled;
        success &= Check(
            disabled.Initialize(1, true) == LaxoriWorkSchedulerResult::Success,
            "untracked scheduler initializes");
        LaxoriWorkPacket disabledPacket(
            20,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            1,
            ExecuteChild,
            nullptr);
        success &= Check(
            disabled.SubmitDeferredConcurrentTracked(
                &disabledPacket,
                LaxoriCompletionWorkKind::Decrement,
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::CompletionDisabled,
            "tracked API fails closed when disabled");
        disabled.Shutdown();

        LaxoriWorkScheduler shutdown;
        SchedulerContext context;
        context.scheduler = &shutdown;
        context.scheduleSweep = false;
        success &= Check(
            shutdown.Initialize(
                1,
                true,
                true,
                SchedulerDecrementsDrained,
                SchedulerOverallDrained,
                &context) == LaxoriWorkSchedulerResult::Success,
            "shutdown scheduler initializes");
        LaxoriWorkPacket queued(
            21,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            1,
            ExecuteChild,
            &context);
        success &= Check(
            shutdown.SubmitDeferredConcurrentTracked(
                &queued,
                LaxoriCompletionWorkKind::Decrement,
                LaxoriDeferredWorkPriority::Normal) ==
                LaxoriWorkSchedulerResult::Success,
            "producer-side tracked packet queues");
        shutdown.Shutdown();
        success &= Check(
            queued.GetState() == LaxoriWorkPacketState::CallerOwned &&
                queued.GetGeneration() == 0,
            "shutdown returns tracked packet ownership");
        success &= Check(
            context.decrementOrder.load(std::memory_order_seq_cst) == 0 &&
                context.overallOrder.load(std::memory_order_seq_cst) == 0,
            "shutdown cancellation suppresses zero callbacks");

        LaxoriWorkScheduler executing;
        SchedulerContext executingContext;
        executingContext.scheduler = &executing;
        executingContext.scheduleSweep = false;
        success &= Check(
            executing.Initialize(
                1,
                true,
                true,
                SchedulerDecrementsDrained,
                SchedulerOverallDrained,
                &executingContext) == LaxoriWorkSchedulerResult::Success,
            "executing shutdown scheduler initializes");
        LaxoriWorkPacket executingPacket(
            22,
            LaxoriWorkBucketStage::Unconstrained,
            references,
            1,
            ExecuteChild,
            &executingContext);
        success &= Check(
            executing.SubmitDeferredConcurrentTracked(
                &executingPacket,
                LaxoriCompletionWorkKind::Decrement,
                LaxoriDeferredWorkPriority::Normal) ==
                    LaxoriWorkSchedulerResult::Success &&
                executing.BeginStwCycle() ==
                    LaxoriWorkSchedulerResult::Success &&
                executing.WaitForCycleCompletion(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                executing.ResumeConcurrentWork() ==
                    LaxoriWorkSchedulerResult::Success &&
                executing.PublishDeferredConcurrentWork(1) ==
                    LaxoriWorkSchedulerResult::Success &&
                WaitUntil(executingContext.childStarted),
            "tracked callback executes before shutdown");
        std::atomic<bool> shutdownReturned{false};
        std::thread shutdownThread([&]()
        {
            executing.Shutdown();
            shutdownReturned.store(true, std::memory_order_release);
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        success &= Check(
            !shutdownReturned.load(std::memory_order_acquire),
            "shutdown waits for executing callback");
        executingContext.releaseChild.store(true, std::memory_order_release);
        shutdownThread.join();
        success &= Check(
            shutdownReturned.load(std::memory_order_acquire) &&
                executingPacket.GetState() == LaxoriWorkPacketState::Completed,
            "worker joins before embedded state destruction");
        return success;
    }

    bool ValidateTrackedEagerSeam()
    {
        uintptr_t references[] = {5, 6};
        LaxoriWorkScheduler scheduler;
        SchedulerContext context;
        context.scheduler = &scheduler;
        context.scheduleSweep = false;
        context.releaseChild.store(true, std::memory_order_release);
        bool success = Check(
            scheduler.Initialize(
                1,
                true,
                true,
                SchedulerDecrementsDrained,
                SchedulerOverallDrained,
                &context) == LaxoriWorkSchedulerResult::Success,
            "eager seam scheduler initializes");
        LaxoriWorkPacket eager(
            30,
            LaxoriRCProcessDecs,
            references,
            2,
            ExecuteChild,
            &context);
        success &= Check(
            scheduler.SubmitTracked(
                &eager,
                LaxoriCompletionWorkKind::Decrement) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.BeginStwCycle() ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCycleCompletion(TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success,
            "tracked eager decrement executes in STW bucket");
        LaxoriCompletionSnapshot beforePublish{};
        success &= Check(
            scheduler.GetCompletionSnapshot(1, &beforePublish) ==
                    LaxoriWorkSchedulerResult::Success &&
                beforePublish.decrementOutstanding == 1 &&
                beforePublish.overallOutstanding == 1,
            "eager decrement leaves only generation seed");
        success &= Check(
            scheduler.ResumeConcurrentWork() ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.PublishDeferredConcurrentWork(1) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.WaitForCompletion(1, TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                scheduler.ResetCompletedCycle() ==
                    LaxoriWorkSchedulerResult::Success,
            "empty publication completes eager generation");
        scheduler.Shutdown();
        return success;
    }

    // P27 (item 2). The decrements-drained callback may register several sweep packets, and a sweep packet may register
    // the next batch before it completes. The overall callback runs once, after the last of them.
    struct BatchContext
    {
        LaxoriLazyCompletionRegistration first[3];
        std::atomic<uint32_t> overallCallbacks{0};
    };

    LaxoriCompletionCallbackResult BatchDecrementsDrained(
        LaxoriMatureSweepContinuation* continuation,
        void* context)
    {
        BatchContext* state = static_cast<BatchContext*>(context);
        for (LaxoriLazyCompletionRegistration& sweep : state->first)
        {
            if (continuation->RegisterSweep(&sweep) != LaxoriCompletionResult::Success)
            {
                return LaxoriCompletionCallbackResult::Failure;
            }
        }
        return LaxoriCompletionCallbackResult::Success;
    }

    LaxoriCompletionCallbackResult BatchOverallDrained(uint64_t, void* context)
    {
        static_cast<BatchContext*>(context)->overallCallbacks.fetch_add(1, std::memory_order_seq_cst);
        return LaxoriCompletionCallbackResult::Success;
    }

    bool ValidateBatchedSweep()
    {
        BatchContext context;
        LaxoriLazyCompletionGenerationState state;
        LaxoriLazyCompletionRegistration seed;
        bool success = Check(
            state.Initialize(
                21,
                BatchDecrementsDrained,
                BatchOverallDrained,
                &context,
                &seed) == LaxoriCompletionResult::Success &&
                state.Seal(21) == LaxoriCompletionResult::Success,
            "batched sweep generation initializes");
        success &= Check(
            seed.Complete() == LaxoriCompletionResult::Success,
            "seed completion runs the decrements-drained callback");
        LaxoriCompletionSnapshot batch = state.GetSnapshot();
        success &= Check(
            batch.decrementOutstanding == 0 && batch.overallOutstanding == 3 &&
                batch.overallCallbacks == 0 && batch.lifecycle == LaxoriCompletionLifecycle::Draining,
            "the callback registered three sweep packets that keep the generation open");
        LaxoriBlockReleaseGuard guards[3];
        for (size_t index = 0; index < 3; index++)
        {
            success &= Check(
                context.first[index].CreateReleaseGuard(&guards[index]) == LaxoriCompletionResult::Success &&
                    guards[index].IsValid(),
                "every sweep packet of the batch owns a valid release guard");
        }
        LaxoriLazyCompletionRegistration next[2];
        LaxoriLazyCompletionRegistration forged;
        success &= Check(
            context.first[0].RegisterChild(LaxoriCompletionWorkKind::Decrement, &forged) ==
                LaxoriCompletionResult::InvalidArgument,
            "a sweep packet cannot register decrement work");
        success &= Check(
            context.first[0].RegisterChild(LaxoriCompletionWorkKind::MatureSweep, &next[0]) ==
                    LaxoriCompletionResult::Success &&
                context.first[0].RegisterChild(LaxoriCompletionWorkKind::MatureSweep, &next[1]) ==
                    LaxoriCompletionResult::Success &&
                state.GetSnapshot().overallOutstanding == 5,
            "the last packet of a batch registers the packets of the next batch");
        success &= Check(
            context.first[0].Complete() == LaxoriCompletionResult::Success &&
                context.first[1].Complete() == LaxoriCompletionResult::Success &&
                context.first[2].Complete() == LaxoriCompletionResult::Success,
            "the first batch completes");
        LaxoriCompletionSnapshot between = state.GetSnapshot();
        success &= Check(
            between.overallOutstanding == 2 && between.overallCallbacks == 0 &&
                between.lifecycle == LaxoriCompletionLifecycle::Draining && guards[0].IsValid(),
            "the next batch keeps the generation open and the release guard valid");
        success &= Check(
            next[0].Complete() == LaxoriCompletionResult::Success &&
                context.overallCallbacks.load(std::memory_order_seq_cst) == 0 &&
                next[1].Complete() == LaxoriCompletionResult::Success,
            "the overall callback waits for the last packet");
        LaxoriCompletionSnapshot drained = state.GetSnapshot();
        success &= Check(
            drained.overallOutstanding == 0 && drained.overallCallbacks == 1 &&
                context.overallCallbacks.load(std::memory_order_seq_cst) == 1 &&
                drained.lifecycle == LaxoriCompletionLifecycle::Drained,
            "the generation drains exactly once after the last sweep packet");
        return success;
    }
}

int main()
{
    bool success = true;
    success &= ValidateDirectCounter();
    success &= ValidateOverflowAndFailure();
    success &= ValidateSchedulerIntegration();
    success &= ValidateDisabledAndShutdown();
    success &= ValidateTrackedEagerSeam();
    success &= ValidateBatchedSweep();

    if (!success || s_passed != s_checks)
    {
        std::printf(
            "FAIL: %d/%d P3.4 validation checks passed\n",
            s_passed,
            s_checks);
        return 1;
    }

    std::printf(
        "PASS: %d/%d P3.4 validation checks\n",
        s_passed,
        s_checks);
    return 0;
}
