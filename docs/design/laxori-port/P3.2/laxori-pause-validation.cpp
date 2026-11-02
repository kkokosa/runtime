// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "../../../../src/coreclr/gc_laxori/laxori_pause_coordinator.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string_view>
#include <thread>
#include <vector>

namespace
{
    constexpr uint32_t TimeoutMilliseconds = 30'000;
    constexpr size_t StageCount = static_cast<size_t>(LaxoriWorkBucketStage::Count);
    constexpr size_t PauseKindCount = static_cast<size_t>(LaxoriPauseKind::Count);

    int Checks = 0;
    int Failures = 0;

    bool Check(bool condition, const char* message)
    {
        Checks++;
        if (!condition)
        {
            Failures++;
            std::fprintf(stderr, "FAIL: %s\n", message);
        }
        return condition;
    }

    constexpr uint16_t StageBit(LaxoriWorkBucketStage stage)
    {
        return static_cast<uint16_t>(UINT16_C(1) << static_cast<uint8_t>(stage));
    }

    struct AdapterState
    {
        std::atomic<uint32_t> suspends;
        std::atomic<uint32_t> resumes;
        std::atomic<bool> lastFinishedGc;
    };

    void Suspend(void* context)
    {
        static_cast<AdapterState*>(context)->suspends.fetch_add(
            1,
            std::memory_order_relaxed);
    }

    void Resume(bool finishedGc, void* context)
    {
        AdapterState* state = static_cast<AdapterState*>(context);
        state->lastFinishedGc.store(finishedGc, std::memory_order_relaxed);
        state->resumes.fetch_add(1, std::memory_order_relaxed);
    }

    LaxoriPauseRuntimeAdapter NewAdapter(AdapterState* state)
    {
        return {Suspend, Resume, state, false};
    }

    struct ExecutionState
    {
        std::array<std::atomic<uint32_t>, StageCount> executions{};
        std::mutex lock;
        std::condition_variable condition;
        bool blockingStarted = false;
        bool releaseBlocking = false;
        std::atomic<bool> suspendCalled;
        std::atomic<bool> resumableExecutedBeforeSuspend;
    };

    void Execute(LaxoriWorkPacket* packet, size_t, void* context)
    {
        ExecutionState* state = static_cast<ExecutionState*>(context);
        state->executions[static_cast<size_t>(packet->GetStage())].fetch_add(
            1,
            std::memory_order_relaxed);
    }

    void ExecuteBlocking(LaxoriWorkPacket* packet, size_t workerIndex, void* context)
    {
        Execute(packet, workerIndex, context);
        ExecutionState* state = static_cast<ExecutionState*>(context);
        std::unique_lock<std::mutex> guard(state->lock);
        state->blockingStarted = true;
        state->condition.notify_all();
        state->condition.wait(guard, [state]() { return state->releaseBlocking; });
    }

    void ExecuteResumableQueued(LaxoriWorkPacket* packet, size_t workerIndex, void* context)
    {
        ExecutionState* state = static_cast<ExecutionState*>(context);
        if (!state->suspendCalled.load(std::memory_order_acquire))
        {
            state->resumableExecutedBeforeSuspend.store(
                true,
                std::memory_order_release);
        }
        Execute(packet, workerIndex, context);
    }

    bool WaitForBlockingStart(ExecutionState* state)
    {
        std::unique_lock<std::mutex> guard(state->lock);
        return state->condition.wait_for(
            guard,
            std::chrono::milliseconds(TimeoutMilliseconds),
            [state]() { return state->blockingStarted; });
    }

    void ReleaseBlocking(ExecutionState* state)
    {
        std::lock_guard<std::mutex> guard(state->lock);
        state->releaseBlocking = true;
        state->condition.notify_all();
    }

    bool WaitForResumableInterruption(LaxoriWorkScheduler* scheduler)
    {
        std::chrono::steady_clock::time_point deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(1);
        while (std::chrono::steady_clock::now() < deadline)
        {
            if (!scheduler->IsStageEnabled(
                LaxoriWorkBucketStage::ConcurrentResumable))
            {
                return true;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return false;
    }

    std::unique_ptr<LaxoriWorkPacket> NewPacket(
        uint64_t id,
        LaxoriWorkBucketStage stage,
        LaxoriWorkPacket::ExecuteCallback callback,
        void* state)
    {
        static uintptr_t References[] = {1, 2, 3, 4};
        return std::make_unique<LaxoriWorkPacket>(
            id,
            stage,
            References,
            std::size(References),
            callback,
            state);
    }

    bool ValidateTaxonomyAndSchedules()
    {
        constexpr const char* ExpectedNames[] = {
            "Full",
            "RefCount",
            "InitialMark",
            "FinalMark",
        };
        constexpr uint16_t Common =
            StageBit(LaxoriWorkBucketStage::FinishConcurrentWork) |
            StageBit(LaxoriWorkBucketStage::Initial) |
            StageBit(LaxoriWorkBucketStage::Release) |
            StageBit(LaxoriWorkBucketStage::Final);
        constexpr uint16_t ExpectedMasks[] = {
            Common |
                StageBit(LaxoriWorkBucketStage::Prepare) |
                StageBit(LaxoriWorkBucketStage::Closure) |
                StageBit(LaxoriWorkBucketStage::STWRCDecsAndSweep),
            Common,
            Common | StageBit(LaxoriWorkBucketStage::Prepare),
            Common |
                StageBit(LaxoriWorkBucketStage::Prepare) |
                StageBit(LaxoriWorkBucketStage::Closure),
        };

        bool success = true;
        for (size_t index = 0; index < PauseKindCount; index++)
        {
            LaxoriPauseKind kind = static_cast<LaxoriPauseKind>(index);
            LaxoriPauseSchedule schedule{};
            success &= Check(
                std::string_view(LaxoriGetPauseKindName(kind)) == ExpectedNames[index],
                "pause name and ordinal");
            success &= Check(
                LaxoriTryGetPauseSchedule(kind, &schedule),
                "pause schedule exists");
            success &= Check(schedule.kind == kind, "schedule kind identity");
            success &= Check(
                schedule.enabledStageMask == ExpectedMasks[index],
                "exact per-kind stage mask");
        }

        LaxoriPauseSchedule invalid{};
        success &= Check(
            !LaxoriTryGetPauseSchedule(LaxoriPauseKind::Count, &invalid),
            "invalid pause rejected");
        success &= Check(
            !LaxoriTryGetPauseSchedule(LaxoriPauseKind::Full, nullptr),
            "null schedule rejected");
        success &= Check(
            std::string_view(LaxoriGetPauseKindName(LaxoriPauseKind::Count)) == "Invalid",
            "invalid pause name");
        return success;
    }

    bool ValidatePause(LaxoriPauseKind kind)
    {
        LaxoriWorkScheduler scheduler;
        AdapterState adapter{};
        LaxoriPauseCoordinator coordinator;
        ExecutionState execution{};
        bool success = Check(
            scheduler.Initialize(3) == LaxoriWorkSchedulerResult::Success,
            "pause scheduler initializes");
        success &= Check(
            coordinator.Initialize(&scheduler, NewAdapter(&adapter)) ==
                LaxoriPauseCoordinatorResult::Success,
            "pause coordinator initializes");
        success &= Check(
            coordinator.PreparePause(kind) == LaxoriPauseCoordinatorResult::Success,
            "pause prepares");

        LaxoriPauseSchedule schedule{};
        LaxoriTryGetPauseSchedule(kind, &schedule);
        std::vector<std::unique_ptr<LaxoriWorkPacket>> packets;
        uint64_t id = 1;
        for (size_t index = static_cast<size_t>(LaxoriFirstStwStage);
             index < StageCount;
             index++)
        {
            LaxoriWorkBucketStage stage = static_cast<LaxoriWorkBucketStage>(index);
            bool expectedEnabled = LaxoriIsPauseStageEnabled(schedule, stage);
            success &= Check(
                scheduler.IsStageEnabled(stage) == expectedEnabled,
                "stage enabled state matches schedule");
            std::unique_ptr<LaxoriWorkPacket> packet =
                NewPacket(id++, stage, Execute, &execution);
            LaxoriWorkSchedulerResult submitted = scheduler.Submit(packet.get());
            success &= Check(
                submitted == (expectedEnabled ?
                    LaxoriWorkSchedulerResult::Success :
                    LaxoriWorkSchedulerResult::StageDisabled),
                "enabled stage accepts and disabled stage rejects");
            if (expectedEnabled)
            {
                packets.push_back(std::move(packet));
            }
        }

        success &= Check(
            coordinator.StartPause(TimeoutMilliseconds) ==
                LaxoriPauseCoordinatorResult::Success,
            "pause starts");
        success &= Check(
            scheduler.RunStwCycle(TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "pause schedule completes");

        constexpr size_t StwStageCount =
            StageCount - static_cast<size_t>(LaxoriFirstStwStage);
        std::array<LaxoriWorkBucketStage, StwStageCount> opens{};
        std::array<LaxoriWorkBucketStage, StwStageCount> completions{};
        success &= Check(
            scheduler.CopyOpenTrace(opens.data(), opens.size()) == StwStageCount,
            "one open per STW stage");
        success &= Check(
            scheduler.CopyCompletionTrace(completions.data(), completions.size()) ==
                StwStageCount,
            "one completion per STW stage");
        for (size_t index = 0; index < StwStageCount; index++)
        {
            LaxoriWorkBucketStage expected = static_cast<LaxoriWorkBucketStage>(
                static_cast<size_t>(LaxoriFirstStwStage) + index);
            success &= Check(opens[index] == expected, "exact open order");
            success &= Check(completions[index] == expected, "exact completion order");
            success &= Check(scheduler.IsStageCompleted(expected), "stage completed");
            uint32_t executions =
                execution.executions[static_cast<size_t>(expected)].load(
                    std::memory_order_relaxed);
            success &= Check(
                executions == (LaxoriIsPauseStageEnabled(schedule, expected) ? 1U : 0U),
                "only enabled stage executes");
        }

        success &= Check(
            coordinator.CompletePause(TimeoutMilliseconds) ==
                LaxoriPauseCoordinatorResult::Success,
            "pause completes and resets");
        success &= Check(
            coordinator.GetState() == LaxoriPauseCoordinatorState::Idle,
            "coordinator returns idle");
        success &= Check(
            coordinator.GetCurrentPauseKind() == LaxoriPauseKind::Count,
            "pause kind clears on reset");
        success &= Check(
            adapter.suspends.load(std::memory_order_relaxed) == 1 &&
                adapter.resumes.load(std::memory_order_relaxed) == 1,
            "one suspend and one resume");
        success &= Check(
            coordinator.GetMetrics(kind).count == 1,
            "per-kind count recorded");
        for (size_t index = static_cast<size_t>(LaxoriFirstStwStage);
             index < StageCount;
             index++)
        {
            LaxoriWorkBucketStage stage = static_cast<LaxoriWorkBucketStage>(index);
            success &= Check(scheduler.IsStageEnabled(stage), "reset enables STW stage");
            success &= Check(!scheduler.IsStageOpen(stage), "reset closes STW stage");
            success &= Check(!scheduler.IsStageCompleted(stage), "reset clears completion");
        }

        scheduler.Shutdown();
        return success;
    }

    bool ValidateIllegalTransitions()
    {
        LaxoriWorkScheduler scheduler;
        AdapterState adapter{};
        LaxoriPauseCoordinator coordinator;
        bool success = Check(
            coordinator.PreparePause(LaxoriPauseKind::Full) ==
                LaxoriPauseCoordinatorResult::NotInitialized,
            "prepare before initialization rejected");
        success &= Check(
            coordinator.StartPause(1) == LaxoriPauseCoordinatorResult::NotInitialized,
            "start before initialization rejected");
        success &= Check(
            coordinator.CompletePause(1) == LaxoriPauseCoordinatorResult::NotInitialized,
            "complete before initialization rejected");
        success &= Check(
            scheduler.Initialize(2) == LaxoriWorkSchedulerResult::Success,
            "illegal transition scheduler initializes");
        success &= Check(
            coordinator.Initialize(&scheduler, NewAdapter(&adapter)) ==
                LaxoriPauseCoordinatorResult::Success,
            "illegal transition coordinator initializes");
        success &= Check(
            coordinator.Initialize(&scheduler, NewAdapter(&adapter)) ==
                LaxoriPauseCoordinatorResult::AlreadyInitialized,
            "duplicate initialization rejected");
        success &= Check(
            coordinator.StartPause(1) == LaxoriPauseCoordinatorResult::InvalidState,
            "start without prepare rejected");
        success &= Check(
            coordinator.PreparePause(LaxoriPauseKind::Count) ==
                LaxoriPauseCoordinatorResult::InvalidArgument,
            "invalid kind rejected");
        success &= Check(
            coordinator.PreparePause(LaxoriPauseKind::RefCount) ==
                LaxoriPauseCoordinatorResult::Success,
            "valid prepare accepted");
        success &= Check(
            coordinator.PreparePause(LaxoriPauseKind::Full) ==
                LaxoriPauseCoordinatorResult::InvalidState,
            "duplicate prepare rejected");
        success &= Check(
            coordinator.CompletePause(1) ==
                LaxoriPauseCoordinatorResult::InvalidState,
            "complete before start rejected");
        success &= Check(
            !scheduler.IsStageEnabled(LaxoriWorkBucketStage::Prepare) &&
                !scheduler.IsStageEnabled(LaxoriWorkBucketStage::Closure) &&
                !scheduler.IsStageEnabled(LaxoriWorkBucketStage::STWRCDecsAndSweep),
            "RefCount disables all unnecessary stages");
        scheduler.Shutdown();
        return success;
    }

    bool ValidateInterruptionAndResume()
    {
        struct InterruptionAdapterState
        {
            AdapterState adapter;
            ExecutionState* execution;
        };
        auto suspend = [](void* context)
        {
            InterruptionAdapterState* state =
                static_cast<InterruptionAdapterState*>(context);
            state->adapter.suspends.fetch_add(1, std::memory_order_relaxed);
            state->execution->suspendCalled.store(true, std::memory_order_release);
        };
        auto resume = [](bool finishedGc, void* context)
        {
            InterruptionAdapterState* state =
                static_cast<InterruptionAdapterState*>(context);
            state->adapter.lastFinishedGc.store(
                finishedGc,
                std::memory_order_relaxed);
            state->adapter.resumes.fetch_add(1, std::memory_order_relaxed);
        };

        LaxoriWorkScheduler scheduler;
        LaxoriPauseCoordinator coordinator;
        ExecutionState execution{};
        InterruptionAdapterState adapter{{}, &execution};
        LaxoriPauseRuntimeAdapter runtimeAdapter{
            suspend,
            resume,
            &adapter,
            false,
        };
        bool success = Check(
            scheduler.Initialize(1) == LaxoriWorkSchedulerResult::Success,
            "interruption scheduler initializes");
        success &= Check(
            scheduler.EnableConcurrentStage(LaxoriWorkBucketStage::ConcurrentResumable) ==
                LaxoriWorkSchedulerResult::Success,
            "resumable stage enables");

        std::unique_ptr<LaxoriWorkPacket> blocking = NewPacket(
            100,
            LaxoriWorkBucketStage::ConcurrentResumable,
            ExecuteBlocking,
            &execution);
        std::unique_ptr<LaxoriWorkPacket> queued = NewPacket(
            101,
            LaxoriWorkBucketStage::ConcurrentResumable,
            ExecuteResumableQueued,
            &execution);
        success &= Check(
            scheduler.Submit(blocking.get(), 0) == LaxoriWorkSchedulerResult::Success,
            "blocking resumable packet submits");
        success &= Check(WaitForBlockingStart(&execution), "resumable packet starts");
        success &= Check(
            scheduler.Submit(queued.get(), 0) == LaxoriWorkSchedulerResult::Success,
            "queued resumable packet submits");
        success &= Check(
            coordinator.Initialize(&scheduler, runtimeAdapter) ==
                LaxoriPauseCoordinatorResult::Success &&
                coordinator.PreparePause(LaxoriPauseKind::Full) ==
                    LaxoriPauseCoordinatorResult::Success,
            "interruption pause prepares");

        std::atomic<bool> startFinished(false);
        LaxoriPauseCoordinatorResult startResult = LaxoriPauseCoordinatorResult::InvalidState;
        std::thread starter(
            [&]()
            {
                startResult = coordinator.StartPause(TimeoutMilliseconds);
                startFinished.store(true, std::memory_order_release);
            });

        success &= Check(
            WaitForResumableInterruption(&scheduler),
            "resumable bucket closes before interruption waits");
        success &= Check(
            !startFinished.load(std::memory_order_acquire),
            "pause waits for executing resumable packet boundary");
        LaxoriPauseSchedule fullSchedule{};
        LaxoriTryGetPauseSchedule(LaxoriPauseKind::Full, &fullSchedule);
        success &= Check(
            scheduler.EnableConcurrentStage(
                LaxoriWorkBucketStage::ConcurrentResumable) ==
                LaxoriWorkSchedulerResult::Busy,
            "interruption rejects concurrent re-enable");
        success &= Check(
            scheduler.ResumeConcurrentWork() == LaxoriWorkSchedulerResult::Busy,
            "interruption rejects broad concurrent resume");
        success &= Check(
            scheduler.ConfigureStwStages(fullSchedule.enabledStageMask) ==
                LaxoriWorkSchedulerResult::InvalidState,
            "interruption rejects schedule replacement");
        success &= Check(
            execution.executions[
                static_cast<size_t>(LaxoriWorkBucketStage::ConcurrentResumable)].load(
                    std::memory_order_relaxed) == 1,
            "queued resumable packet does not execute during interruption");
        ReleaseBlocking(&execution);
        starter.join();
        success &= Check(
            startResult == LaxoriPauseCoordinatorResult::Success,
            "pause starts after packet boundary");
        success &= Check(
            coordinator.CompletePause(TimeoutMilliseconds) ==
                LaxoriPauseCoordinatorResult::Success,
            "interruption pause completes");
        success &= Check(
            scheduler.WaitForPacket(queued.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "queued resumable packet executes after resume");
        success &= Check(
            execution.executions[
                static_cast<size_t>(LaxoriWorkBucketStage::ConcurrentResumable)].load(
                    std::memory_order_relaxed) == 2,
            "resumable packets execute exactly once");
        success &= Check(
            !execution.resumableExecutedBeforeSuspend.load(
                std::memory_order_acquire),
            "queued resumable packet cannot execute before suspension");
        scheduler.Shutdown();
        return success;
    }

    struct DeferredPauseState
    {
        AdapterState adapter{};
        ExecutionState execution{};
        LaxoriWorkScheduler* scheduler;
        std::atomic<bool> executedBeforeResume{false};
        std::atomic<uint32_t> rejectedEarlyPublications{0};
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
        std::atomic<uint32_t> decrementCallbacks{0};
        std::atomic<uint32_t> overallCallbacks{0};
#endif
    };

    void SuspendDeferred(void* context)
    {
        Suspend(&static_cast<DeferredPauseState*>(context)->adapter);
    }

    void ResumeDeferred(bool finishedGc, void* context)
    {
        DeferredPauseState* state = static_cast<DeferredPauseState*>(context);
        if (state->scheduler->PublishDeferredConcurrentWork(
                state->scheduler->GetGeneration()) == LaxoriWorkSchedulerResult::InvalidState)
        {
            state->rejectedEarlyPublications.fetch_add(1, std::memory_order_relaxed);
        }
        Resume(finishedGc, &state->adapter);
    }

    void ExecuteDeferred(LaxoriWorkPacket* packet, size_t workerIndex, void* context)
    {
        DeferredPauseState* state = static_cast<DeferredPauseState*>(context);
        if (state->adapter.resumes.load(std::memory_order_acquire) != packet->GetGeneration())
        {
            state->executedBeforeResume.store(true, std::memory_order_release);
        }
        ExecuteBlocking(packet, workerIndex, &state->execution);
    }

#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
    LaxoriCompletionCallbackResult DecrementsDrained(
        LaxoriMatureSweepContinuation*, void* context)
    {
        static_cast<DeferredPauseState*>(context)->decrementCallbacks.fetch_add(
            1, std::memory_order_relaxed);
        return LaxoriCompletionCallbackResult::Success;
    }

    LaxoriCompletionCallbackResult OverallDrained(uint64_t, void* context)
    {
        static_cast<DeferredPauseState*>(context)->overallCallbacks.fetch_add(
            1, std::memory_order_relaxed);
        return LaxoriCompletionCallbackResult::Success;
    }
#endif

    bool ValidateDeferredPause()
    {
        LaxoriWorkScheduler scheduler;
        DeferredPauseState state{};
        state.scheduler = &scheduler;
        bool success = Check(
            scheduler.Initialize(
                2, true
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
                , true, DecrementsDrained, OverallDrained, &state
#endif
                ) == LaxoriWorkSchedulerResult::Success,
            "combined deferred scheduler initializes");
        LaxoriPauseCoordinator coordinator;
        LaxoriPauseRuntimeAdapter adapter{
            SuspendDeferred, ResumeDeferred, &state, false,
        };
        success &= Check(
            coordinator.Initialize(&scheduler, adapter) == LaxoriPauseCoordinatorResult::Success,
            "combined deferred coordinator initializes");

        for (uint64_t generation = 1; generation <= 3; generation++)
        {
            std::unique_ptr<LaxoriWorkPacket> packet = NewPacket(
                300 + generation, LaxoriWorkBucketStage::Unconstrained,
                ExecuteDeferred, &state);
            state.execution.blockingStarted = false;
            state.execution.releaseBlocking = false;
            success &= Check(
                coordinator.PreparePause(LaxoriPauseKind::RefCount) ==
                    LaxoriPauseCoordinatorResult::Success,
                "combined pause retires prior generation and prepares");
            success &= Check(
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
                scheduler.SubmitDeferredConcurrentTracked(
                    packet.get(), LaxoriCompletionWorkKind::Decrement,
                    LaxoriDeferredWorkPriority::Prioritized)
#else
                scheduler.SubmitDeferredConcurrent(
                    packet.get(), LaxoriDeferredWorkPriority::Prioritized)
#endif
                    == LaxoriWorkSchedulerResult::Success,
                "combined pause owns deferred decrement");
            success &= Check(
                coordinator.StartPause(TimeoutMilliseconds) ==
                    LaxoriPauseCoordinatorResult::Success,
                "combined pause starts");
            success &= Check(
                coordinator.CompletePause(TimeoutMilliseconds) ==
                    LaxoriPauseCoordinatorResult::Success,
                "combined pause resumes and publishes without waiting for lazy work");
            bool started = WaitForBlockingStart(&state.execution);
            success &= Check(started, "combined decrement executes after publication");
            success &= Check(
                coordinator.PreparePause(LaxoriPauseKind::RefCount) ==
                    LaxoriPauseCoordinatorResult::SchedulerFailure,
                "next pause cannot retire executing lazy ownership");
            ReleaseBlocking(&state.execution);
            success &= Check(
                scheduler.WaitForPacket(packet.get(), TimeoutMilliseconds) ==
                    LaxoriWorkSchedulerResult::Success &&
                    scheduler.WaitForIdle(TimeoutMilliseconds) ==
                        LaxoriWorkSchedulerResult::Success,
                "combined lazy packet and scheduler drain");
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
            LaxoriCompletionSnapshot snapshot{};
            success &= Check(
                scheduler.GetCompletionSnapshot(generation, &snapshot) ==
                    LaxoriWorkSchedulerResult::Success &&
                    snapshot.overallOutstanding == 0 &&
                    snapshot.decrementOutstanding == 0 &&
                    snapshot.lifecycle == LaxoriCompletionLifecycle::Drained,
                "combined completion ownership drains before reset");
#endif
        }
        success &= Check(
            state.rejectedEarlyPublications.load(std::memory_order_relaxed) == 3 &&
                !state.executedBeforeResume.load(std::memory_order_acquire),
            "all combined publications occur after actual resume");
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
        success &= Check(
            state.decrementCallbacks.load(std::memory_order_relaxed) == 3 &&
                state.overallCallbacks.load(std::memory_order_relaxed) == 3,
            "combined decrement and overall transitions occur once per generation");
#endif
        success &= Check(
            scheduler.ResetCompletedCycle() == LaxoriWorkSchedulerResult::Success &&
                scheduler.Shutdown() == LaxoriWorkSchedulerResult::Success,
            "combined generation retires and shuts down");
        return success;
    }

    struct RollbackState
    {
        AdapterState adapter;
        LaxoriWorkScheduler* scheduler;
        LaxoriWorkPacket* packet;
        ExecutionState* execution;
    };

    void SuspendAndRaceUnconstrained(void* context)
    {
        RollbackState* state = static_cast<RollbackState*>(context);
        state->adapter.suspends.fetch_add(1, std::memory_order_relaxed);
        if (state->scheduler->Submit(state->packet) ==
            LaxoriWorkSchedulerResult::Success)
        {
            WaitForBlockingStart(state->execution);
        }
    }

    void ResumeRollback(bool finishedGc, void* context)
    {
        RollbackState* state = static_cast<RollbackState*>(context);
        state->adapter.lastFinishedGc.store(finishedGc, std::memory_order_relaxed);
        state->adapter.resumes.fetch_add(1, std::memory_order_relaxed);
    }

    bool ValidateDrainAndRollback()
    {
        LaxoriWorkScheduler scheduler;
        ExecutionState execution{};
        bool success = Check(
            scheduler.Initialize(2) == LaxoriWorkSchedulerResult::Success,
            "rollback scheduler initializes");
        std::unique_ptr<LaxoriWorkPacket> blocking = NewPacket(
            200,
            LaxoriWorkBucketStage::Unconstrained,
            ExecuteBlocking,
            &execution);
        RollbackState state{{}, &scheduler, blocking.get(), &execution};
        LaxoriPauseRuntimeAdapter adapter{
            SuspendAndRaceUnconstrained,
            ResumeRollback,
            &state,
            false,
        };
        LaxoriPauseCoordinator coordinator;
        success &= Check(
            coordinator.Initialize(&scheduler, adapter) ==
                LaxoriPauseCoordinatorResult::Success &&
                coordinator.PreparePause(LaxoriPauseKind::Full) ==
                    LaxoriPauseCoordinatorResult::Success,
            "rollback pause prepares");
        success &= Check(
            coordinator.StartPause(TimeoutMilliseconds) ==
                LaxoriPauseCoordinatorResult::SchedulerFailure,
            "post-suspension drain race fails start");
        success &= Check(WaitForBlockingStart(&execution), "rollback packet started");
        success &= Check(
            state.adapter.suspends.load(std::memory_order_relaxed) == 1 &&
                state.adapter.resumes.load(std::memory_order_relaxed) == 1,
            "failed start resumes runtime exactly once");
        success &= Check(
            coordinator.GetState() == LaxoriPauseCoordinatorState::Prepared,
            "failed start restores prepared state");
        ReleaseBlocking(&execution);
        success &= Check(
            scheduler.WaitForPacket(blocking.get(), TimeoutMilliseconds) ==
                LaxoriWorkSchedulerResult::Success,
            "rollback packet drains");
        scheduler.Shutdown();
        return success;
    }

    std::atomic<size_t> LastExecutionIndex{SIZE_MAX};

    void ExecuteRecordingIndex(LaxoriWorkPacket* packet, size_t workerIndex, void* context)
    {
        LastExecutionIndex.store(workerIndex, std::memory_order_relaxed);
        Execute(packet, workerIndex, context);
    }

    // P29. A pause whose stages have one packet each runs on the pause thread alone: no worker wakes, and the packets see the
    // execution index GetWorkerCount().
    bool ValidatePauseThreadRunsSmallStages()
    {
        LaxoriWorkScheduler scheduler;
        AdapterState adapter{};
        LaxoriPauseCoordinator coordinator;
        ExecutionState execution{};
        bool success = Check(
            scheduler.Initialize(3) == LaxoriWorkSchedulerResult::Success &&
                coordinator.Initialize(&scheduler, NewAdapter(&adapter)) == LaxoriPauseCoordinatorResult::Success,
            "small pause initializes");
        // Let the workers park.
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        uint64_t wakesBefore = scheduler.GetMetrics().wakes;
        success &= Check(
            coordinator.PreparePause(LaxoriPauseKind::RefCount) == LaxoriPauseCoordinatorResult::Success,
            "small pause prepares");
        std::vector<std::unique_ptr<LaxoriWorkPacket>> packets;
        uint64_t id = 1;
        for (LaxoriWorkBucketStage stage : {LaxoriWorkBucketStage::FinishConcurrentWork, LaxoriRCProcessIncs,
                LaxoriWorkBucketStage::Release, LaxoriWorkBucketStage::Final})
        {
            packets.push_back(NewPacket(id++, stage, ExecuteRecordingIndex, &execution));
            success &= Check(
                scheduler.Submit(packets.back().get()) == LaxoriWorkSchedulerResult::Success,
                "small pause submits");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        success &= Check(
            scheduler.GetMetrics().wakes == wakesBefore,
            "a submission for a closed stop-the-world stage wakes no worker");
        success &= Check(
            coordinator.StartPause(TimeoutMilliseconds) == LaxoriPauseCoordinatorResult::Success,
            "small pause starts");
        success &= Check(
            coordinator.CompletePause(TimeoutMilliseconds) == LaxoriPauseCoordinatorResult::Success,
            "small pause completes");
        for (const std::unique_ptr<LaxoriWorkPacket>& packet : packets)
        {
            success &= Check(
                execution.executions[static_cast<size_t>(packet->GetStage())].load(std::memory_order_relaxed) == 1,
                "small pause packet executes once");
        }
        success &= Check(
            LastExecutionIndex.load(std::memory_order_relaxed) == scheduler.GetWorkerCount(),
            "the pause thread runs the packets of a small pause");
        success &= Check(
            scheduler.GetMetrics().wakes == wakesBefore,
            "a small pause wakes no worker");
        scheduler.Shutdown();
        return success;
    }
}

int main()
{
    bool success = ValidateTaxonomyAndSchedules();
    for (size_t index = 0; index < PauseKindCount; index++)
    {
        success &= ValidatePause(static_cast<LaxoriPauseKind>(index));
    }
    success &= ValidateIllegalTransitions();
    success &= ValidateInterruptionAndResume();
    success &= ValidateDrainAndRollback();
    success &= ValidateDeferredPause();
    success &= ValidatePauseThreadRunsSmallStages();

    if (!success || Failures != 0)
    {
        std::fprintf(stderr, "FAIL: %d/%d checks failed\n", Failures, Checks);
        return 1;
    }

    std::printf("PASS: %d/%d P3.2 pause checks\n", Checks, Checks);
    return 0;
}
