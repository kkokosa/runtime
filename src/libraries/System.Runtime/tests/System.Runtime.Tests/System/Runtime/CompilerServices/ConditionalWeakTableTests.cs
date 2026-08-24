// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace System.Runtime.CompilerServices.Tests
{
    public class ConditionalWeakTableTests
    {
        [Fact]
        public static void InvalidArgs_Throws()
        {
            var cwt = new ConditionalWeakTable<object, object>();

            object ignored;
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.Add(null, new object())); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.TryGetValue(null, out ignored)); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.Remove(null)); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.Remove(null, out _)); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.GetOrAdd(null, new object())); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.GetOrAdd(null, k => new object())); // null key
            AssertExtensions.Throws<ArgumentNullException>("key", () => cwt.GetOrAdd(null, (k, a) => new object(), 42)); // null key
            AssertExtensions.Throws<ArgumentNullException>("valueFactory", () => cwt.GetOrAdd(new object(), null)); // null factory
            AssertExtensions.Throws<ArgumentNullException>("valueFactory", () => cwt.GetOrAdd(new object(), null, 42)); // null factory
            AssertExtensions.Throws<ArgumentNullException>("createValueCallback", () => cwt.GetValue(new object(), null)); // null delegate

            object key = new object();
            cwt.Add(key, key);
            AssertExtensions.Throws<ArgumentException>(null, () => cwt.Add(key, key)); // duplicate key
        }

        [ConditionalTheory(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        [InlineData(1, false)]
        [InlineData(1, true)]
        [InlineData(100, false)]
        [InlineData(100, true)]
        public static void Add(int numObjects, bool tryAdd)
        {
            // Isolated to ensure we drop all references even in debug builds where lifetime is extended by the JIT to the end of the method
            Func<int, Tuple<ConditionalWeakTable<object, object>, WeakReference[], WeakReference[]>> body = count =>
            {
                object[] keys = Enumerable.Range(0, count).Select(_ => new object()).ToArray();
                object[] values = Enumerable.Range(0, count).Select(_ => new object()).ToArray();
                var cwt = new ConditionalWeakTable<object, object>();

                for (int i = 0; i < count; i++)
                {
                    if (tryAdd)
                    {
                        Assert.True(cwt.TryAdd(keys[i], values[i]));
                    }
                    else
                    {
                        cwt.Add(keys[i], values[i]);
                    }
                }

                for (int i = 0; i < count; i++)
                {
                    object value;
                    Assert.True(cwt.TryGetValue(keys[i], out value));
                    Assert.Same(values[i], value);
                    Assert.Same(value, cwt.GetOrCreateValue(keys[i]));
                    Assert.Same(value, cwt.GetValue(keys[i], _ => new object()));
                    Assert.Same(value, cwt.GetOrAdd(keys[i], new object()));
                    Assert.Same(value, cwt.GetOrAdd(keys[i], k => new object()));
                    Assert.Same(value, cwt.GetOrAdd(keys[i], (k, a) => new object(), 42));
                }

                return Tuple.Create(cwt, keys.Select(k => new WeakReference(k)).ToArray(), values.Select(v => new WeakReference(v)).ToArray());
            };

            Tuple<ConditionalWeakTable<object, object>, WeakReference[], WeakReference[]> result = body(numObjects);
            GC.Collect();

            Assert.NotNull(result.Item1);

            for (int i = 0; i < numObjects; i++)
            {
                Assert.False(result.Item2[i].IsAlive, $"Expected not to find key #{i}");
                Assert.False(result.Item3[i].IsAlive, $"Expected not to find value #{i}");
            }
        }

        [Fact]
        public static void TryAdd_ConditionallyAdds()
        {
            var cwt = new ConditionalWeakTable<object, object>();

            object value1 = new object();
            object value2 = new object();
            object value3 = new object();
            object value4 = new object();
            object value5 = new object();
            object found;

            object key1 = new object();
            Assert.True(cwt.TryAdd(key1, value1));
            Assert.False(cwt.TryAdd(key1, value2));
            Assert.True(cwt.TryGetValue(key1, out found));
            Assert.Same(value1, found);
            Assert.Equal(1, cwt.Count());

            object key2 = new object();
            Assert.True(cwt.TryAdd(key2, value1));
            Assert.False(cwt.TryAdd(key2, value2));
            Assert.True(cwt.TryGetValue(key2, out found));
            Assert.Same(value1, found);
            Assert.Equal(2, cwt.Count());

            object key3 = new object();
            Assert.Same(value1, cwt.GetOrAdd(key1, new object()));
            Assert.Same(value3, cwt.GetOrAdd(key3, value3));
            Assert.Same(value3, cwt.GetOrAdd(key3, new object()));
            Assert.True(cwt.Remove(key3));
            Assert.Same(value4, cwt.GetOrAdd(key3, value4));

            object key4 = new object();
            Assert.Same(value4, cwt.GetOrAdd(key4, k => value4));
            Assert.Same(value4, cwt.GetOrAdd(key4, k => new object()));
            Assert.True(cwt.Remove(key4));
            Assert.Same(value5, cwt.GetOrAdd(key4, k => value5));

            object key5 = new object();
            Assert.Same(value5, cwt.GetOrAdd(key5, (k, a) => a, value5));
            Assert.Same(value5, cwt.GetOrAdd(key5, (k, a) => a, new object()));
            Assert.True(cwt.Remove(key5));
            Assert.Same(value4, cwt.GetOrAdd(key5, (k, a) => a, value4));

            GC.KeepAlive(key1);
            GC.KeepAlive(key2);
            GC.KeepAlive(key3);
            GC.KeepAlive(key4);
            GC.KeepAlive(key5);
        }

        [Theory]
        [InlineData(1)]
        [InlineData(100)]
        public static void AddMany_ThenRemoveAll(int numObjects)
        {
            object[] keys = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            var cwt = new ConditionalWeakTable<object, object>();

            for (int i = 0; i < numObjects; i++)
            {
                cwt.Add(keys[i], values[i]);
            }

            for (int i = 0; i < numObjects; i++)
            {
                Assert.Same(values[i], cwt.GetValue(keys[i], _ => new object()));
            }

            for (int i = 0; i < numObjects; i++)
            {
                Assert.True(cwt.Remove(keys[i]));
                Assert.False(cwt.Remove(keys[i]));
            }

            for (int i = 0; i < numObjects; i++)
            {
                object ignored;
                Assert.False(cwt.TryGetValue(keys[i], out ignored));
            }
        }

        [Theory]
        [InlineData(1)]
        [InlineData(100)]
        public static void AddMany_ThenRemoveAll_ValidateRemovedValue(int numObjects)
        {
            object[] keys = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            var cwt = new ConditionalWeakTable<object, object>();

            for (int i = 0; i < numObjects; i++)
            {
                cwt.Add(keys[i], values[i]);
            }

            for (int i = 0; i < numObjects; i++)
            {
                Assert.Same(values[i], cwt.GetValue(keys[i], _ => new object()));
            }

            for (int i = 0; i < numObjects; i++)
            {
                Assert.True(cwt.Remove(keys[i], out var value));
                Assert.False(cwt.Remove(keys[i], out _));
                Assert.Same(values[i], value);
            }

            for (int i = 0; i < numObjects; i++)
            {
                object ignored;
                Assert.False(cwt.TryGetValue(keys[i], out ignored));
            }
        }

        [Theory]
        [InlineData(100)]
        public static void AddRemoveIteratively(int numObjects)
        {
            object[] keys = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            var cwt = new ConditionalWeakTable<object, object>();

            for (int i = 0; i < numObjects; i++)
            {
                cwt.Add(keys[i], values[i]);
                Assert.Same(values[i], cwt.GetValue(keys[i], _ => new object()));
                Assert.True(cwt.Remove(keys[i]));
                Assert.False(cwt.Remove(keys[i]));
            }
        }

        [Theory]
        [InlineData(100)]
        public static void AddRemoveIteratively_ValidateRemovedValue(int numObjects)
        {
            object[] keys = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            var cwt = new ConditionalWeakTable<object, object>();

            for (int i = 0; i < numObjects; i++)
            {
                cwt.Add(keys[i], values[i]);
                Assert.Same(values[i], cwt.GetValue(keys[i], _ => new object()));
                Assert.True(cwt.Remove(keys[i], out var value));
                Assert.False(cwt.Remove(keys[i], out _));
                Assert.Same(values[i], value);
            }
        }

        [Fact]
        public static void Concurrent_AddMany_DropReferences() // no asserts, just making nothing throws
        {
            var cwt = new ConditionalWeakTable<object, object>();
            for (int i = 0; i < 10000; i++)
            {
                cwt.Add(i.ToString(), i.ToString());
                if (i % 1000 == 0) GC.Collect();
            }
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_Add_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.25);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    cwt.Add(key, value);
                    Assert.Same(value, cwt.GetValue(key, _ => new object()));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_Add_Read_Remove_ValidateRemovedValue_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.25);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    cwt.Add(key, value);
                    Assert.Same(value, cwt.GetValue(key, _ => new object()));
                    Assert.True(cwt.Remove(key, out var removedValue));
                    Assert.False(cwt.Remove(key, out _));
                    Assert.Same(value, removedValue);
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Add_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();

            // Here we use a lower threshold to reduce test time (same below).
            // This applies to all the new 'GetOrAdd' tests in this file.
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    cwt.Add(key, value);
                    Assert.Same(value, cwt.GetOrAdd(key, new object()));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_Add_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    cwt.Add(key, value);
                    Assert.Same(value, cwt.GetOrAdd(key, _ => new object()));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_WithArg_Add_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    cwt.Add(key, value);
                    Assert.Same(value, cwt.GetOrAdd(key, (k, a) => a, new object()));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetValue_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.25);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    Assert.Same(value, cwt.GetValue(key, _ => value));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    Assert.Same(value, cwt.GetOrAdd(key, value));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    Assert.Same(value, cwt.GetOrAdd(key, _ => value));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_WithArg_Read_Remove_DifferentObjects()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    object key = new object();
                    object value = new object();
                    Assert.Same(value, cwt.GetOrAdd(key, (k, a) => a, value));
                    Assert.True(cwt.Remove(key));
                    Assert.False(cwt.Remove(key));
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetValue_Read_Remove_SameObject()
        {
            object key = new object();
            object value = new object();

            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.25);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    Assert.Same(value, cwt.GetValue(key, _ => value));
                    cwt.Remove(key);
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Read_Remove_SameObject()
        {
            object key = new object();
            object value = new object();

            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    Assert.Same(value, cwt.GetOrAdd(key, value));
                    cwt.Remove(key);
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_Read_Remove_SameObject()
        {
            object key = new object();
            object value = new object();

            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    Assert.Same(value, cwt.GetOrAdd(key, _ => value));
                    cwt.Remove(key);
                }
            });
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsMultithreadingSupported))]
        public static void Concurrent_GetOrAdd_Factory_WithArg_Read_Remove_SameObject()
        {
            object key = new object();
            object value = new object();

            var cwt = new ConditionalWeakTable<object, object>();
            DateTime end = DateTime.UtcNow + TimeSpan.FromSeconds(0.10);
            Parallel.For(0, Environment.ProcessorCount, i =>
            {
                while (DateTime.UtcNow < end)
                {
                    Assert.Same(value, cwt.GetOrAdd(key, (k, a) => a, value));
                    cwt.Remove(key);
                }
            });
        }

        [System.Runtime.CompilerServices.MethodImplAttribute(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static WeakReference GetWeakCondTabRef(out ConditionalWeakTable<object, object> cwt_out, out object key_out)
        {
            var key = new object();
            var value = new object();

            var cwt = new ConditionalWeakTable<object, object>();

            cwt.Add(key, value);
            cwt.Remove(key);

            // Return 3 values to the caller, drop everything else on the floor.
            cwt_out = cwt;
            key_out = key;
            return new WeakReference(value);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void AddRemove_DropValue()
        {
            // Verify that the removed entry is not keeping the value alive
            ConditionalWeakTable<object, object> cwt;
            object key;

            var wrValue = GetWeakCondTabRef(out cwt, out key);

            GC.Collect();
            Assert.False(wrValue.IsAlive);

            GC.KeepAlive(cwt);
            GC.KeepAlive(key);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported), nameof(PlatformDetection.IsNotNativeAot))]
        public static void ChurnWithPermanentEntry_DoesNotRetainReplacedContainers()
        {
            (ConditionalWeakTable<object, object> table, object permanentKey, WeakReference[] retiredContainers) =
                CreateTableWithRetiredContainers(1024);

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            Assert.All(retiredContainers, container => Assert.False(container.IsAlive));
            GC.KeepAlive(permanentKey);
            GC.KeepAlive(table);
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static (ConditionalWeakTable<object, object>, object, WeakReference[]) CreateTableWithRetiredContainers(int count)
        {
            var table = new ConditionalWeakTable<object, object>();
            object permanentKey = new();
            table.Add(permanentKey, new object());

            FieldInfo containerField = table.GetType().GetField("_container", BindingFlags.Instance | BindingFlags.NonPublic);
            object previousContainer = containerField.GetValue(table);
            var retiredContainers = new List<WeakReference>(count);

            while (retiredContainers.Count < count)
            {
                object key = new();
                table.Add(key, new object());

                object currentContainer = containerField.GetValue(table);
                if (!ReferenceEquals(previousContainer, currentContainer))
                {
                    retiredContainers.Add(new WeakReference(previousContainer, trackResurrection: true));
                    previousContainer = currentContainer;
                }

                table.Remove(key);
            }

            return (table, permanentKey, retiredContainers.ToArray());
        }

        // A table that is only reachable through a finalizable object is discovered by the GC after the
        // main marking work is over, when finalization resurrects the object graph. Its values still have
        // to be kept alive by their keys.
        private sealed class ResurrectingTableHolder
        {
            internal static ConditionalWeakTable<object, object> s_resurrectedTable;
            internal static object s_resurrectedKey;

            private readonly ConditionalWeakTable<object, object> _table;
            private readonly object _key;

            internal ResurrectingTableHolder(ConditionalWeakTable<object, object> table, object key)
            {
                _table = table;
                _key = key;
            }

            ~ResurrectingTableHolder()
            {
                s_resurrectedTable = _table;
                s_resurrectedKey = _key;
            }
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void ValueSurvivesWhenTableIsOnlyResurrectedByFinalization()
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            static WeakReference CreateResurrectingTable()
            {
                var table = new ConditionalWeakTable<object, object>();
                object key = new();
                object value = new();
                table.Add(key, value);

                // The holder is the only reference to the table and the key; the value is only reachable
                // through the table's entry.
                _ = new ResurrectingTableHolder(table, key);

                // Track resurrection: a short weak reference is severed before finalization runs, so it
                // would report the value as dead even when the entry is handled correctly.
                return new WeakReference(value, trackResurrection: true);
            }

            WeakReference weakValue = CreateResurrectingTable();

            GC.Collect();
            GC.WaitForPendingFinalizers();

            Assert.NotNull(ResurrectingTableHolder.s_resurrectedTable);
            Assert.NotNull(ResurrectingTableHolder.s_resurrectedKey);
            Assert.True(weakValue.IsAlive);

            Assert.True(ResurrectingTableHolder.s_resurrectedTable.TryGetValue(ResurrectingTableHolder.s_resurrectedKey, out object value));
            Assert.NotNull(value);
            Assert.Same(weakValue.Target, value);

            // A second collection with the table now strongly reachable must not disturb the entry either.
            GC.Collect();

            Assert.True(ResurrectingTableHolder.s_resurrectedTable.TryGetValue(ResurrectingTableHolder.s_resurrectedKey, out object valueAfter));
            Assert.Same(value, valueAfter);

            ResurrectingTableHolder.s_resurrectedTable = null;
            ResurrectingTableHolder.s_resurrectedKey = null;
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void EntriesSurviveCollectionsInterleavedWithABackgroundCollection()
        {
            const int EntryCount = 2048;

            var keys = new object[EntryCount];
            var values = new object[EntryCount];
            var table = new ConditionalWeakTable<object, object>();

            for (int i = 0; i < EntryCount; i++)
            {
                keys[i] = new object();
                values[i] = new object();
                table.Add(keys[i], values[i]);
            }

            // Start a non blocking gen2 collection and then force ephemeral collections while it runs, so
            // that foreground collections move objects the background collection is still tracking.
            for (int round = 0; round < 8; round++)
            {
                GC.Collect(2, GCCollectionMode.Forced, blocking: false);

                for (int i = 0; i < 64; i++)
                {
                    GC.KeepAlive(new byte[8 * 1024]);
                    GC.Collect(0, GCCollectionMode.Forced, blocking: true, compacting: true);
                }
            }

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            for (int i = 0; i < EntryCount; i++)
            {
                Assert.True(table.TryGetValue(keys[i], out object value), $"entry {i} was lost");
                Assert.Same(values[i], value);
            }

            GC.KeepAlive(table);
        }

        private sealed class DeepNode
        {
            internal DeepNode Next;
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void ChainedEntriesSurviveMarkStackOverflow()
        {
            // A graph far deeper than the GC's mark stack forces the mark stack to overflow, which makes
            // the GC fall back to re-walking the recorded overflow address range. Entries discovered only
            // by that fallback still have to go through the promotion fixed point, and under Server GC the
            // promotion that rescues one entry can be performed by a different heap than the one that owns
            // the next entry in the chain.
            const int DeepChainLength = 200_000;
            const int LinkCount = 4096;

            var table = new ConditionalWeakTable<object, object>();
            var links = new object[LinkCount];

            // Allocate the links from several threads so that, under Server GC, consecutive links land on
            // different heaps and the chain below has to be resolved across heaps.
            int threadCount = Math.Max(2, Math.Min(8, Environment.ProcessorCount));
            var threads = new Thread[threadCount];
            for (int t = 0; t < threadCount; t++)
            {
                int start = t;
                threads[t] = new Thread(() =>
                {
                    for (int i = start; i < LinkCount; i += threadCount)
                    {
                        links[i] = new object();
                    }
                });
                threads[t].Start();
            }
            foreach (Thread thread in threads)
            {
                thread.Join();
            }

            // Entry i's value is entry i+1's key, so only a complete fixed point keeps the whole chain
            // alive: promoting one dependent is what makes the next entry's target reachable.
            for (int i = 0; i < LinkCount - 1; i++)
            {
                table.Add(links[i], links[i + 1]);
            }

            object head = links[0];
            var weakLinks = new WeakReference[LinkCount];
            for (int i = 0; i < LinkCount; i++)
            {
                weakLinks[i] = new WeakReference(links[i], trackResurrection: true);
            }

            // Drop the only strong references to links 1..N-1; from here they are kept alive purely by the
            // chain of conditional weak table entries rooted at head.
            Array.Clear(links, 0, links.Length);

            DeepNode deep = null;
            for (int i = 0; i < DeepChainLength; i++)
            {
                deep = new DeepNode { Next = deep };
            }

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.KeepAlive(deep);
            deep = null;
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            for (int i = 0; i < LinkCount; i++)
            {
                Assert.True(weakLinks[i].IsAlive, $"link {i} was collected");
            }

            object node = head;
            for (int i = 1; i < LinkCount; i++)
            {
                Assert.True(table.TryGetValue(node, out object next), $"entry {i} was lost");
                Assert.NotNull(next);
                Assert.Same(weakLinks[i].Target, next);
                node = next;
            }

            GC.KeepAlive(head);
            GC.KeepAlive(table);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void NestedTablesDiscoveredDuringPromotionSurvive()
        {
            // Promoting a value marks it, and marking it can reach a whole new ConditionalWeakTable
            // whose entries the GC has not looked at yet in this pass. Only running the promotion pass
            // to a fixed point keeps those nested entries alive.
            //
            // Width is chosen so that the outer table alone contributes more entries than a registration
            // chunk holds, and so that promoting the first few of them brings in many more registrations
            // while there are still entries left to walk.
            const int Width = 128;

            var outerKeys = new object[Width];
            var innerKeys = new object[Width * Width];
            var leaves = new object[Width * Width];

            var outer = new ConditionalWeakTable<object, object>();
            var inners = new ConditionalWeakTable<object, object>[Width];

            for (int i = 0; i < Width; i++)
            {
                outerKeys[i] = new object();
                inners[i] = new ConditionalWeakTable<object, object>();

                for (int j = 0; j < Width; j++)
                {
                    int index = (i * Width) + j;
                    innerKeys[index] = new object();
                    leaves[index] = new object();
                    inners[i].Add(innerKeys[index], leaves[index]);
                }

                // The inner table is only reachable as this entry's value, so its entries cannot be reached
                // until this entry has been promoted.
                outer.Add(outerKeys[i], inners[i]);
            }

            var weakLeaves = new WeakReference[Width * Width];
            for (int i = 0; i < weakLeaves.Length; i++)
            {
                weakLeaves[i] = new WeakReference(leaves[i], trackResurrection: true);
            }

            // Drop the direct references to the inner tables and the leaves. Every key stays rooted, so each
            // entry is live; the inner tables and leaves are reachable only through the outer entries.
            Array.Clear(inners, 0, inners.Length);
            Array.Clear(leaves, 0, leaves.Length);

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            for (int i = 0; i < Width; i++)
            {
                Assert.True(outer.TryGetValue(outerKeys[i], out object innerObj), $"outer entry {i} was lost");
                var inner = Assert.IsType<ConditionalWeakTable<object, object>>(innerObj);

                for (int j = 0; j < Width; j++)
                {
                    int index = (i * Width) + j;
                    Assert.True(inner.TryGetValue(innerKeys[index], out object leaf), $"inner entry {index} was lost");
                    Assert.NotNull(leaf);
                    Assert.True(weakLeaves[index].IsAlive, $"leaf {index} was collected");
                    Assert.Same(weakLeaves[index].Target, leaf);
                }
            }

            GC.KeepAlive(outer);
            GC.KeepAlive(outerKeys);
            GC.KeepAlive(innerKeys);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void OldTableKeepsYoungEntryAliveDuringGen0Collection()
        {
            // The GC is allowed to skip a table's storage during an ephemeral collection when it knows that
            // nothing it could collect is reachable from it. Adding a freshly allocated key and value to a
            // table whose storage has aged into gen2 is exactly the mutation that has to defeat that.
            [MethodImpl(MethodImplOptions.NoInlining)]
            static (object Key, WeakReference Value) AddYoungEntry(ConditionalWeakTable<object, object> table)
            {
                object key = new();
                object value = new();
                table.Add(key, value);

                return (key, new WeakReference(value, trackResurrection: true));
            }

            var table = new ConditionalWeakTable<object, object>();
            object agedKey = new();
            table.Add(agedKey, new object());

            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
            GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

            (object key, WeakReference weakValue) = AddYoungEntry(table);

            GC.Collect(0, GCCollectionMode.Forced, blocking: true, compacting: true);

            Assert.True(weakValue.IsAlive);
            Assert.True(table.TryGetValue(key, out object value));
            Assert.Same(weakValue.Target, value);

            // Also make sure a gen1 collection, which condemns a different set of generations, agrees.
            GC.Collect(1, GCCollectionMode.Forced, blocking: true, compacting: true);

            Assert.True(table.TryGetValue(key, out object valueAfterGen1));
            Assert.Same(value, valueAfterGen1);

            GC.KeepAlive(agedKey);
            GC.KeepAlive(table);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void EntriesSurviveResizeAndCompaction()
        {
            // Every resize replaces the container's storage, so this walks entries through a long series of
            // replacements and then compacts, with pinned objects interleaved so that some of the storage
            // ends up next to a pinned plug.
            const int EntryCount = 4096;

            var keys = new object[EntryCount];
            var values = new object[EntryCount];
            var pins = new GCHandle[64];
            var table = new ConditionalWeakTable<object, object>();

            try
            {
                for (int i = 0; i < EntryCount; i++)
                {
                    if (i < pins.Length)
                    {
                        pins[i] = GCHandle.Alloc(new byte[16], GCHandleType.Pinned);
                    }

                    keys[i] = new object();
                    values[i] = new object();
                    table.Add(keys[i], values[i]);
                }

                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);
                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

                for (int i = 0; i < EntryCount; i++)
                {
                    Assert.True(table.TryGetValue(keys[i], out object value), $"entry {i} was lost");
                    Assert.Same(values[i], value);
                }

                // Removing every other entry and then growing again forces the compacting resize path,
                // which rebuilds the storage from scratch.
                for (int i = 0; i < EntryCount; i += 2)
                {
                    Assert.True(table.Remove(keys[i]));
                }

                for (int i = 0; i < EntryCount; i += 2)
                {
                    table.Add(keys[i], values[i]);
                }

                GC.Collect(2, GCCollectionMode.Forced, blocking: true, compacting: true);

                for (int i = 0; i < EntryCount; i++)
                {
                    Assert.True(table.TryGetValue(keys[i], out object value), $"entry {i} was lost after resize");
                    Assert.Same(values[i], value);
                }
            }
            finally
            {
                for (int i = 0; i < pins.Length; i++)
                {
                    if (pins[i].IsAllocated)
                    {
                        pins[i].Free();
                    }
                }
            }

            GC.KeepAlive(table);
        }

        [System.Runtime.CompilerServices.MethodImplAttribute(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static void GetWeakRefPair(out WeakReference<object> key_out, out WeakReference<object> val_out)
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var key = new object();

            object value = cwt.GetOrCreateValue(key);

            Assert.True(cwt.TryGetValue(key, out value));
            Assert.Equal(value, cwt.GetValue(key, k => new object()));

            val_out = new WeakReference<object>(value, false);
            key_out = new WeakReference<object>(key, false);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void GetOrCreateValue()
        {
            WeakReference<object> wrValue;
            WeakReference<object> wrKey;

            GetWeakRefPair(out wrKey, out wrValue);

            GC.Collect();

            // key and value must be collected
            object obj;
            Assert.False(wrValue.TryGetTarget(out obj));
            Assert.False(wrKey.TryGetTarget(out obj));
        }

        [System.Runtime.CompilerServices.MethodImplAttribute(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        static void GetWeakRefValPair(out WeakReference<object> key_out, out WeakReference<object> val_out)
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var key = new object();

            object value = cwt.GetValue(key, k => new object());

            Assert.True(cwt.TryGetValue(key, out value));
            Assert.Equal(value, cwt.GetOrCreateValue(key));

            val_out = new WeakReference<object>(value, false);
            key_out = new WeakReference<object>(key, false);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void GetValue()
        {
            WeakReference<object> wrValue;
            WeakReference<object> wrKey;

            GetWeakRefValPair(out wrKey, out wrValue);

            GC.Collect();

            // key and value must be collected
            object obj;
            Assert.False(wrValue.TryGetTarget(out obj));
            Assert.False(wrKey.TryGetTarget(out obj));
        }

        [Theory]
        [InlineData(0)]
        [InlineData(1)]
        [InlineData(100)]
        public static void Clear_AllValuesRemoved(int numObjects)
        {
            var cwt = new ConditionalWeakTable<object, object>();

            MethodInfo clear = cwt.GetType().GetMethod("Clear", BindingFlags.NonPublic | BindingFlags.Instance);
            if (clear == null)
            {
                // Couldn't access the Clear method; skip the test.
                return;
            }

            object[] keys = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, numObjects).Select(_ => new object()).ToArray();

            for (int iter = 0; iter < 2; iter++)
            {
                // Add the objects
                for (int i = 0; i < numObjects; i++)
                {
                    cwt.Add(keys[i], values[i]);
                    Assert.Same(values[i], cwt.GetValue(keys[i], _ => new object()));
                }

                // Clear the table
                clear.Invoke(cwt, null);

                // Verify the objects are removed
                for (int i = 0; i < numObjects; i++)
                {
                    object ignored;
                    Assert.False(cwt.TryGetValue(keys[i], out ignored));
                }

                // Do it a couple of times, to make sure the table is still usable after a clear.
            }
        }

        [Fact]
        public static void AddOrUpdateDataTest()
        {
            var cwt = new ConditionalWeakTable<string, string>();
            string key = "key1";
            cwt.AddOrUpdate(key, "value1");

            string value;
            Assert.True(cwt.TryGetValue(key, out value));
            Assert.Equal("value1", value);
            Assert.Equal(value, cwt.GetOrCreateValue(key));
            Assert.Equal(value, cwt.GetValue(key, k => "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, k => "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, (k, a) => a, "value1"));

            Assert.Throws<ArgumentNullException>(() => cwt.AddOrUpdate(null, "value2"));

            cwt.AddOrUpdate(key, "value2");
            Assert.True(cwt.TryGetValue(key, out value));
            Assert.Equal("value2", value);
            Assert.Equal(value, cwt.GetOrCreateValue(key));
            Assert.Equal(value, cwt.GetValue(key, k => "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, k => "value1"));
            Assert.Equal(value, cwt.GetOrAdd(key, (k, a) => a, "value1"));
        }

        [Fact]
        public static void Clear_EmptyTable()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            cwt.Clear(); // no exception
            cwt.Clear();
        }

        [Fact]
        public static void Clear_AddThenEmptyRepeatedly_ItemsRemoved()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            object key = new object(), value = new object();
            object result;
            for (int i = 0; i < 3; i++)
            {
                cwt.Add(key, value);

                Assert.True(cwt.TryGetValue(key, out result));
                Assert.Same(value, result);

                cwt.Clear();

                Assert.False(cwt.TryGetValue(key, out result));
                Assert.Null(result);
            }
        }

        [Fact]
        public static void Clear_AddMany_Clear_AllItemsRemoved()
        {
            var cwt = new ConditionalWeakTable<object, object>();

            object[] keys = Enumerable.Range(0, 33).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, keys.Length).Select(_ => new object()).ToArray();
            for (int i = 0; i < keys.Length; i++)
            {
                cwt.Add(keys[i], values[i]);
            }

            Assert.Equal(keys.Length, ((IEnumerable<KeyValuePair<object, object>>)cwt).Count());

            cwt.Clear();

            Assert.Equal(0, ((IEnumerable<KeyValuePair<object, object>>)cwt).Count());

            GC.KeepAlive(keys);
            GC.KeepAlive(values);
        }

        [Fact]
        public static void GetEnumerator_Empty_ReturnsEmptyEnumerator()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;
            Assert.Equal(0, enumerable.Count());
        }

        [Fact]
        public static void GetEnumerator_AddedAndRemovedItems_AppropriatelyShowUpInEnumeration()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object key1 = new object(), value1 = new object();

            for (int i = 0; i < 20; i++) // adding and removing multiple times, across internal container boundary
            {
                cwt.Add(key1, value1);
                Assert.Equal(1, enumerable.Count());
                Assert.Equal(new KeyValuePair<object, object>(key1, value1), enumerable.First());

                Assert.True(cwt.Remove(key1));
                Assert.Equal(0, enumerable.Count());
            }

            GC.KeepAlive(key1);
            GC.KeepAlive(value1);
        }

        [ConditionalFact(typeof(PlatformDetection), nameof(PlatformDetection.IsPreciseGcSupported))]
        public static void GetEnumerator_CollectedItemsNotEnumerated()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            // Delegate to add collectible items to the table, separated out
            // to avoid the JIT extending the lifetimes of the temporaries
            Action<ConditionalWeakTable<object, object>> addItem =
                t => t.Add(new object(), new object());

            for (int i = 0; i < 10; i++) addItem(cwt);
            GC.Collect();
            Assert.Equal(0, enumerable.Count());
        }

        [Fact]
        public static void GetEnumerator_MultipleEnumeratorsReturnSameResults()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object[] keys = Enumerable.Range(0, 33).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, keys.Length).Select(_ => new object()).ToArray();
            for (int i = 0; i < keys.Length; i++)
            {
                cwt.Add(keys[i], values[i]);
            }

            using (IEnumerator<KeyValuePair<object, object>> enumerator1 = enumerable.GetEnumerator())
            using (IEnumerator<KeyValuePair<object, object>> enumerator2 = enumerable.GetEnumerator())
            {
                while (enumerator1.MoveNext())
                {
                    Assert.True(enumerator2.MoveNext());
                    Assert.Equal(enumerator1.Current, enumerator2.Current);
                }
                Assert.False(enumerator2.MoveNext());
            }

            GC.KeepAlive(keys);
            GC.KeepAlive(values);
        }

        [Fact]
        public static void GetEnumerator_RemovedItems_RemovedFromResults()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object[] keys = Enumerable.Range(0, 33).Select(_ => new object()).ToArray();
            object[] values = Enumerable.Range(0, keys.Length).Select(_ => new object()).ToArray();
            for (int i = 0; i < keys.Length; i++)
            {
                cwt.Add(keys[i], values[i]);
            }

            for (int i = 0; i < keys.Length; i++)
            {
                Assert.Equal(keys.Length - i, enumerable.Count());
                Assert.Equal(
                    Enumerable.Range(i, keys.Length - i).Select(j => new KeyValuePair<object, object>(keys[j], values[j])),
                    enumerable);
                cwt.Remove(keys[i]);
            }
            Assert.Equal(0, enumerable.Count());

            GC.KeepAlive(keys);
            GC.KeepAlive(values);
        }

        [Fact]
        public static void GetEnumerator_ItemsAddedAfterGetEnumeratorNotIncluded()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object key1 = new object(), key2 = new object(), value1 = new object(), value2 = new object();

            cwt.Add(key1, value1);
            IEnumerator<KeyValuePair<object, object>> enumerator1 = enumerable.GetEnumerator();
            cwt.Add(key2, value2);
            IEnumerator<KeyValuePair<object, object>> enumerator2 = enumerable.GetEnumerator();

            Assert.True(enumerator1.MoveNext());
            Assert.Equal(new KeyValuePair<object, object>(key1, value1), enumerator1.Current);
            Assert.False(enumerator1.MoveNext());

            Assert.True(enumerator2.MoveNext());
            Assert.Equal(new KeyValuePair<object, object>(key1, value1), enumerator2.Current);
            Assert.True(enumerator2.MoveNext());
            Assert.Equal(new KeyValuePair<object, object>(key2, value2), enumerator2.Current);
            Assert.False(enumerator2.MoveNext());

            enumerator1.Dispose();
            enumerator2.Dispose();

            GC.KeepAlive(key1);
            GC.KeepAlive(key2);
            GC.KeepAlive(value1);
            GC.KeepAlive(value2);
        }

        [Fact]
        public static void GetEnumerator_ItemsRemovedAfterGetEnumeratorNotIncluded()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object key1 = new object(), key2 = new object(), value1 = new object(), value2 = new object();

            cwt.Add(key1, value1);
            cwt.Add(key2, value2);
            IEnumerator<KeyValuePair<object, object>> enumerator1 = enumerable.GetEnumerator();
            cwt.Remove(key1);
            IEnumerator<KeyValuePair<object, object>> enumerator2 = enumerable.GetEnumerator();

            Assert.True(enumerator1.MoveNext());
            Assert.Equal(new KeyValuePair<object, object>(key2, value2), enumerator1.Current);
            Assert.False(enumerator1.MoveNext());

            Assert.True(enumerator2.MoveNext());
            Assert.Equal(new KeyValuePair<object, object>(key2, value2), enumerator2.Current);
            Assert.False(enumerator2.MoveNext());

            enumerator1.Dispose();
            enumerator2.Dispose();

            GC.KeepAlive(key1);
            GC.KeepAlive(key2);
            GC.KeepAlive(value1);
            GC.KeepAlive(value2);
        }

        [Fact]
        public static void GetEnumerator_ItemsClearedAfterGetEnumeratorNotIncluded()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object key1 = new object(), key2 = new object(), value1 = new object(), value2 = new object();

            cwt.Add(key1, value1);
            cwt.Add(key2, value2);
            IEnumerator<KeyValuePair<object, object>> enumerator1 = enumerable.GetEnumerator();
            cwt.Clear();
            IEnumerator<KeyValuePair<object, object>> enumerator2 = enumerable.GetEnumerator();

            Assert.False(enumerator1.MoveNext());
            Assert.False(enumerator2.MoveNext());

            enumerator1.Dispose();
            enumerator2.Dispose();

            GC.KeepAlive(key1);
            GC.KeepAlive(key2);
            GC.KeepAlive(value1);
            GC.KeepAlive(value2);
        }

        [Fact]
        public static void GetEnumerator_Current_ThrowsOnInvalidUse()
        {
            var cwt = new ConditionalWeakTable<object, object>();
            var enumerable = (IEnumerable<KeyValuePair<object, object>>)cwt;

            object key1 = new object(), value1 = new object();
            cwt.Add(key1, value1);

            using (IEnumerator<KeyValuePair<object, object>> enumerator = enumerable.GetEnumerator())
            {
                Assert.Throws<InvalidOperationException>(() => enumerator.Current); // before first MoveNext
            }

            GC.KeepAlive(key1);
            GC.KeepAlive(value1);
        }
    }
}
