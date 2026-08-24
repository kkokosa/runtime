// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Xunit;

namespace System.Runtime.Tests
{
    // NOTE: DependentHandle is already heavily tested indirectly through ConditionalWeakTable<,>.
    // This class contains some specific tests for APIs that are only relevant when used directly.
    public class DependentHandleTests
    {
        [Fact]
        public void GetNullTarget()
        {
            object target = new();
            DependentHandle handle = new(null, null);

            Assert.True(handle.IsAllocated);
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);

            handle.Dispose();
        }

        [Fact]
        public void GetNotNullTarget()
        {
            object target = new();
            DependentHandle handle = new(target, null);

            // A handle with a set target and no dependent is valid
            Assert.True(handle.IsAllocated);
            Assert.Same(target, handle.Target);
            Assert.Null(handle.Dependent);

            handle.Dispose();
        }

        [Fact]
        public void SetTargetToNull_StateIsConsistent()
        {
            object target = new(), dependent = new();
            DependentHandle handle = new(target, dependent);

            Assert.True(handle.IsAllocated);
            Assert.Same(handle.Target, target);
            Assert.Same(handle.Dependent, dependent);

            handle.Target = null;

            Assert.True(handle.IsAllocated);
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);

            handle.Dispose();
        }

        [Fact]
        public void SetTargetToNull_RepeatedCallsAreFine()
        {
            object target = new(), dependent = new();
            DependentHandle handle = new(target, dependent);

            handle.Target = null;

            Assert.True(handle.IsAllocated);
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);

            handle.Target = null;
            handle.Target = null;
            handle.Target = null;

            Assert.True(handle.IsAllocated);
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);

            handle.Dispose();
        }

        [Fact]
        public void GetSetDependent()
        {
            object target = new(), dependent = new();
            DependentHandle handle = new(target, null);

            // The target can be retrieved correctly
            Assert.True(handle.IsAllocated);
            Assert.Same(target, handle.Target);
            Assert.Null(handle.Dependent);

            handle.Dependent = dependent;

            // The dependent can also be retrieved correctly
            Assert.Same(target, handle.Target);
            Assert.Same(dependent, handle.Dependent);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void TargetKeepsDependentAlive()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle Initialize(out object target, out WeakReference weakDependent)
            {
                target = new object();

                object dependent = new();

                weakDependent = new WeakReference(dependent);

                return new DependentHandle(target, dependent);
            }

            DependentHandle handle = Initialize(out object target, out WeakReference dependent);

            GC.Collect();

            // The dependent has to still be alive as the target has a strong reference
            Assert.Same(target, handle.Target);
            Assert.True(dependent.IsAlive);
            Assert.Same(dependent.Target, handle.Dependent);

            GC.KeepAlive(target);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void DependentDoesNotKeepTargetAlive()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle Initialize(out WeakReference weakTarget, out object dependent)
            {
                dependent = new object();

                object target = new();

                weakTarget = new WeakReference(target);

                return new DependentHandle(target, dependent);
            }

            DependentHandle handle = Initialize(out WeakReference target, out object dependent);

            GC.Collect();

            // The target has to be collected, as there were no strong references to it
            Assert.Null(handle.Target);
            Assert.False(target.IsAlive);

            GC.KeepAlive(target);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void DependentIsCollectedOnTargetNotReachable()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle Initialize(out WeakReference weakTarget, out WeakReference weakDependent)
            {
                object target = new(), dependent = new();

                weakTarget = new WeakReference(target);
                weakDependent = new WeakReference(dependent);

                return new DependentHandle(target, dependent);
            }

            DependentHandle handle = Initialize(out WeakReference target, out WeakReference dependent);

            GC.Collect();

            // Both target and dependent have to be collected, as there were no strong references to either
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);
            Assert.False(target.IsAlive);
            Assert.False(dependent.IsAlive);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void DependentIsCollectedOnTargetNotReachable_EvenWithReferenceCycles()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle Initialize(out WeakReference weakTarget, out WeakReference weakDependent)
            {
                object target = new();
                ObjectWithReference dependent = new() { Reference = target };

                weakTarget = new WeakReference(target);
                weakDependent = new WeakReference(dependent);

                return new DependentHandle(target, dependent);
            }

            DependentHandle handle = Initialize(out WeakReference target, out WeakReference dependent);

            GC.Collect();

            // Both target and dependent have to be collected, as there were no strong references to either.
            // The fact that the dependent has a strong reference back to the target should not affect this.
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);
            Assert.False(target.IsAlive);
            Assert.False(dependent.IsAlive);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void ChainedHandlesAreProcessedToFixedPoint()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static (DependentHandle First, DependentHandle Second) Initialize(
                out object root,
                out WeakReference weakLeaf)
            {
                root = new object();
                object intermediate = new();
                object leaf = new();
                weakLeaf = new WeakReference(leaf);

                DependentHandle first = new(root, intermediate);
                DependentHandle second = new(intermediate, leaf);

                return (first, second);
            }

            (DependentHandle first, DependentHandle second) = Initialize(out object root, out WeakReference leaf);

            GC.Collect();

            Assert.True(leaf.IsAlive);
            Assert.Same(leaf.Target, second.Dependent);
            GC.KeepAlive(root);

            first.Dispose();
            second.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void OldHandleKeepsNewDependentAliveDuringGen0Collection()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static WeakReference SetYoungDependent(ref DependentHandle handle)
            {
                object dependent = new();
                handle.Dependent = dependent;

                return new WeakReference(dependent);
            }

            object target = new();
            DependentHandle handle = new(target, null);

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            Assert.Equal(2, GC.GetGeneration(target));

            WeakReference dependent = SetYoungDependent(ref handle);
            GC.Collect(0, GCCollectionMode.Forced, blocking: true);

            Assert.True(dependent.IsAlive);
            Assert.Same(dependent.Target, handle.Dependent);
            GC.KeepAlive(target);

            handle.Dispose();
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void ManyHandlesSurviveEphemeralCollection()
        {
            const int HandleCount = 4096;
            var retiredHandles = new DependentHandle[HandleCount];

            for (int i = 0; i < retiredHandles.Length; i++)
            {
                retiredHandles[i] = new DependentHandle(new object(), new object());
            }

            for (int i = 0; i < retiredHandles.Length; i++)
            {
                retiredHandles[i].Dispose();
            }

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            var handles = new DependentHandle[HandleCount];
            var targets = new object[HandleCount];
            var dependents = new object[HandleCount];

            try
            {
                for (int i = 0; i < handles.Length; i++)
                {
                    targets[i] = new object();
                    dependents[i] = new object();
                    handles[i] = new DependentHandle(targets[i], dependents[i]);
                }

                GC.Collect(0, GCCollectionMode.Forced, blocking: true, compacting: true);

                for (int i = 0; i < handles.Length; i++)
                {
                    Assert.Same(targets[i], handles[i].Target);
                    Assert.Same(dependents[i], handles[i].Dependent);
                }
            }
            finally
            {
                for (int i = 0; i < handles.Length; i++)
                {
                    handles[i].Dispose();
                }
            }
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void OldHandleKeepsYoungTargetAliveDuringGen0Collection()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle CreateWithYoungTarget(out object target, out object dependent)
            {
                target = new object();
                dependent = new object();

                return new DependentHandle(target, dependent);
            }

            // Age a batch of handles into gen2 first, so the handle observed below is old while its
            // target and dependent are freshly allocated in gen0.
            var old = new DependentHandle[64];
            for (int i = 0; i < old.Length; i++)
            {
                old[i] = new DependentHandle(new object(), new object());
            }

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            DependentHandle handle = CreateWithYoungTarget(out object target, out object dependent);

            GC.Collect(0, GCCollectionMode.Forced, blocking: true);

            Assert.Same(target, handle.Target);
            Assert.Same(dependent, handle.Dependent);

            handle.Dispose();
            for (int i = 0; i < old.Length; i++)
            {
                old[i].Dispose();
            }
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void HandlesSurviveCompactionNextToPinnedObjects()
        {
            const int Count = 512;

            var handles = new DependentHandle[Count];
            var targets = new object[Count];
            var dependents = new object[Count];
            var pins = new GCHandle[Count];

            try
            {
                // Interleave pinned objects with the handles' backing storage so that some of it ends
                // up immediately next to a pinned plug, which is the case the GC has to relocate
                // through saved plug info rather than in place.
                for (int i = 0; i < Count; i++)
                {
                    pins[i] = GCHandle.Alloc(new byte[16], GCHandleType.Pinned);

                    targets[i] = new object();
                    dependents[i] = new object();
                    handles[i] = new DependentHandle(targets[i], dependents[i]);
                }

                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

                for (int i = 0; i < Count; i++)
                {
                    Assert.Same(targets[i], handles[i].Target);
                    Assert.Same(dependents[i], handles[i].Dependent);

                    (object target, object dependent) = handles[i].TargetAndDependent;
                    Assert.Same(targets[i], target);
                    Assert.Same(dependents[i], dependent);
                }
            }
            finally
            {
                for (int i = 0; i < Count; i++)
                {
                    handles[i].Dispose();

                    if (pins[i].IsAllocated)
                    {
                        pins[i].Free();
                    }
                }
            }
        }

        private sealed class ObjectWithReference
        {
            public object Reference;
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void DependentIsCollectedAfterTargetIsSetToNull()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static DependentHandle Initialize(out object target, out WeakReference weakDependent)
            {
                target = new object();

                object dependent = new();

                weakDependent = new WeakReference(dependent);

                return new DependentHandle(target, dependent);
            }

            DependentHandle handle = Initialize(out object target, out WeakReference dependent);

            handle.Target = null;

            GC.Collect();

            // After calling StopTracking, the dependent is collected even if
            // target is still alive and the handle itself has not been disposed
            Assert.True(handle.IsAllocated);
            Assert.Null(handle.Target);
            Assert.Null(handle.Dependent);
            Assert.False(dependent.IsAlive);

            GC.KeepAlive(target);

            handle.Dispose();
        }

        [Fact]
        public void GetTarget_ThrowsInvalidOperationException()
        {
            Assert.Throws<InvalidOperationException>(() => default(DependentHandle).Target);
        }

        [Fact]
        public void GetDependent_ThrowsInvalidOperationException()
        {
            Assert.Throws<InvalidOperationException>(() => default(DependentHandle).Dependent);
        }

        [Fact]
        public void SetTarget_NotAllocated_ThrowsInvalidOperationException()
        {
            Assert.Throws<InvalidOperationException>(() =>
            {
                DependentHandle handle = default;
                handle.Target = new object();
            });
        }

        [Fact]
        public void SetTarget_NotNullObject_ThrowsInvalidOperationException()
        {
            Assert.Throws<InvalidOperationException>(() =>
            {
                DependentHandle handle = default;

                try
                {
                    handle.Target = new object();
                }
                finally
                {
                    handle.Dispose();
                }                
            });
        }

        [Fact]
        public void SetDependent_ThrowsInvalidOperationException()
        {
            Assert.Throws<InvalidOperationException>(() =>
            {
                DependentHandle handle = default;
                handle.Dependent = new object();
            });
        }

        [Fact]
        public void Dispose_RepeatedCallsAreFine()
        {
            object target = new(), dependent = new();
            DependentHandle handle = new(target, dependent);

            Assert.True(handle.IsAllocated);

            handle.Dispose();

            Assert.False(handle.IsAllocated);

            handle.Dispose();

            Assert.False(handle.IsAllocated);

            handle.Dispose();
            handle.Dispose();
            handle.Dispose();

            Assert.False(handle.IsAllocated);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public void Dispose_RegistrationCanBeReusedBeforeCollection()
        {
            const int IterationCount = 100_000;

            for (int i = 0; i < IterationCount; i++)
            {
                object target = new();
                object dependent = new();
                DependentHandle handle = new(target, dependent);

                Assert.Same(target, handle.Target);
                Assert.Same(dependent, handle.Dependent);
                handle.Dispose();
            }
        }

        [Fact]
        public void Dispose_ValidOnDefault()
        {
            DependentHandle handle = default;
            Assert.False(handle.IsAllocated);
            handle.Dispose();
        }
    }
}
