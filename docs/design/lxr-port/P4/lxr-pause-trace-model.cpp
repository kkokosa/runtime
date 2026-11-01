// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// Standalone models of the two lock-free protocols of the parallel pause trace. The engine cannot run under
// ThreadSanitizer (its side metadata lives at fixed addresses), so the protocols are written here with the same atomics and
// orders, and checked under TSan and with a mutation for each protocol.
//
// 1. The claim of a mature source (LxrReferenceCounting::TryCopyMature). A worker that sees the block retained or the to-space
//    exhausted leaves the source in place, but only after it has looked at the forwarding state; a worker that copies claims
//    the source first and looks at the flags again after the claim. The invariant: a source is never both copied and used
//    in place. Mutation -DMODEL_NO_RECHECK: the second look is left out.
// 2. The end of the trace of a pause (m_trace_pending). A packet adds the packets that it makes before it takes itself
//    off the count; the helper ends the trace when the count is zero, and then no packet may run any more. Mutation
//    -DMODEL_PENDING_LATE: a packet takes itself off before it adds its children.

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace
{
    constexpr int Objects = 2000;
    constexpr int Threads = 4;

    struct Source
    {
        std::atomic<unsigned> state{0};     // 0 free, 2 claimed, 3 forwarded
        std::atomic<int> usedInPlace{0};
        std::atomic<int> copied{0};
    };

    std::atomic<bool> g_exhausted;

    bool Stays()
    {
        return g_exhausted.load(std::memory_order_acquire);
    }

    // Returns true when the caller uses the source where it is.
    bool TryCopy(Source& source)
    {
        if (Stays())
        {
            std::atomic_thread_fence(std::memory_order_seq_cst);
            unsigned state = source.state.load(std::memory_order_seq_cst);
            if (state == 0)
            {
                return true;
            }
            while (source.state.load(std::memory_order_acquire) == 2)
            {
                std::this_thread::yield();
            }
            return source.state.load(std::memory_order_acquire) != 3;
        }
        unsigned expected = 0;
        // The window between the look at the flags and the claim, made wide so that the violation is found at once.
        for (volatile int spin = 0; spin < 200; spin++)
        {
        }
        if (!source.state.compare_exchange_strong(expected, 2, std::memory_order_seq_cst))
        {
            while (source.state.load(std::memory_order_acquire) == 2)
            {
                std::this_thread::yield();
            }
            return source.state.load(std::memory_order_acquire) != 3;
        }
#ifndef MODEL_NO_RECHECK
        if (Stays())
        {
            source.state.store(0, std::memory_order_seq_cst);
            return true;
        }
#endif
        source.copied.fetch_add(1, std::memory_order_relaxed);
        source.state.store(3, std::memory_order_release);
        return false;
    }

    int RunClaimModel(int rounds)
    {
        int violations = 0;
        for (int round = 0; round < rounds; round++)
        {
            std::vector<Source> sources(Objects);
            g_exhausted.store(false);
            std::atomic<bool> go{false};
            std::vector<std::thread> workers;
            for (int index = 0; index < Threads; index++)
            {
                workers.emplace_back([&, index]()
                {
                    while (!go.load())
                    {
                    }
                    for (int source = 0; source < Objects; source++)
                    {
                        int target = (source + index * 97) % Objects;
                        if (TryCopy(sources[target]))
                        {
                            sources[target].usedInPlace.fetch_add(1, std::memory_order_relaxed);
                        }
                    }
                });
            }
            std::thread exhaust([&]()
            {
                while (!go.load())
                {
                }
                for (volatile int spin = 0; spin < 20000 + (round % 7) * 3000; spin++)
                {
                }
                g_exhausted.store(true, std::memory_order_release);
            });
            go.store(true);
            for (std::thread& worker : workers)
            {
                worker.join();
            }
            exhaust.join();
            for (Source& source : sources)
            {
                // A source that was copied must not be used in place by any thread that saw it free.
                if (source.copied.load() != 0 && source.usedInPlace.load() != 0)
                {
                    violations++;
                }
                if (source.copied.load() > 1)
                {
                    violations++;
                }
            }
        }
        return violations;
    }

    // Model 2.
    std::atomic<long> g_pending{0};
    std::atomic<long> g_run{0};
    std::atomic<long> g_ranAfterEnd{0};
    std::atomic<bool> g_ended{false};

    struct Queue
    {
        std::atomic<int> lock{0};
        std::vector<int> items;
        void Push(int depth)
        {
            while (lock.exchange(1, std::memory_order_acquire) != 0)
            {
            }
            items.push_back(depth);
            lock.store(0, std::memory_order_release);
        }
        bool Pop(int* depth)
        {
            while (lock.exchange(1, std::memory_order_acquire) != 0)
            {
            }
            bool found = !items.empty();
            if (found)
            {
                *depth = items.back();
                items.pop_back();
            }
            lock.store(0, std::memory_order_release);
            return found;
        }
    };

    void RunPacket(Queue& queue, int depth)
    {
        if (g_ended.load(std::memory_order_acquire))
        {
            g_ranAfterEnd.fetch_add(1);
        }
        g_run.fetch_add(1, std::memory_order_relaxed);
        int children = depth == 0 ? 0 : 2;
#ifdef MODEL_PENDING_LATE
        g_pending.fetch_sub(1, std::memory_order_acq_rel);
        for (volatile int spin = 0; spin < 300; spin++)
        {
        }
#endif
        for (int child = 0; child < children; child++)
        {
            g_pending.fetch_add(1, std::memory_order_relaxed);
            queue.Push(depth - 1);
        }
#ifndef MODEL_PENDING_LATE
        g_pending.fetch_sub(1, std::memory_order_acq_rel);
#endif
    }

    int RunPendingModel(int rounds)
    {
        int violations = 0;
        for (int round = 0; round < rounds; round++)
        {
            Queue queue;
            g_pending.store(0);
            g_run.store(0);
            g_ranAfterEnd.store(0);
            g_ended.store(false);
            const int Depth = 9;
            g_pending.fetch_add(1);
            queue.Push(Depth);
            std::atomic<bool> stop{false};
            std::vector<std::thread> workers;
            for (int index = 0; index < Threads - 1; index++)
            {
                workers.emplace_back([&]()
                {
                    int depth;
                    while (!stop.load(std::memory_order_acquire))
                    {
                        if (queue.Pop(&depth))
                        {
                            RunPacket(queue, depth);
                        }
                        else
                        {
                            std::this_thread::yield();
                        }
                    }
                });
            }
            // The helper: it runs packets too, and it ends the trace when the count is zero.
            int depth;
            while (g_pending.load(std::memory_order_acquire) != 0)
            {
                if (queue.Pop(&depth))
                {
                    RunPacket(queue, depth);
                }
            }
            g_ended.store(true, std::memory_order_release);
            long runAtEnd = g_run.load();
            // Wait a little: a packet that runs now is a packet that the end missed.
            for (volatile int spin = 0; spin < 200000; spin++)
            {
            }
            stop.store(true);
            for (std::thread& worker : workers)
            {
                worker.join();
            }
            long expected = (1L << (Depth + 1)) - 1;
            if (runAtEnd != expected || g_run.load() != expected || g_ranAfterEnd.load() != 0)
            {
                violations++;
            }
        }
        return violations;
    }
}

int main(int argc, char** argv)
{
    int rounds = argc > 1 ? atoi(argv[1]) : 200;
    int claim = RunClaimModel(rounds);
    int pending = RunPendingModel(rounds);
    std::printf("claim violations=%d pending violations=%d rounds=%d\n", claim, pending, rounds);
#if defined(MODEL_NO_RECHECK)
    return claim != 0 ? 0 : 1;
#elif defined(MODEL_PENDING_LATE)
    return pending != 0 ? 0 : 1;
#else
    return claim == 0 && pending == 0 ? 0 : 1;
#endif
}
