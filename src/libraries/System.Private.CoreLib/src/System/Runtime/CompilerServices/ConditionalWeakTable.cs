// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Threading;

namespace System.Runtime.CompilerServices
{
    public sealed class ConditionalWeakTable<TKey, [DynamicallyAccessedMembers(DynamicallyAccessedMemberTypes.PublicParameterlessConstructor)] TValue> : IEnumerable<KeyValuePair<TKey, TValue>>
        where TKey : class
        where TValue : class?
    {
        // Lifetimes of keys and values:
        // Inserting a key and value into the dictionary will not
        // prevent the key from dying, even if the key is strongly reachable
        // from the value. Once the key dies, the dictionary automatically removes
        // the key/value entry.
        //
        // Thread safety guarantees:
        // ConditionalWeakTable is fully thread-safe and requires no
        // additional locking to be done by callers.
        //
        // OOM guarantees:
        // Will not corrupt unmanaged handle table on OOM. No guarantees
        // about managed weak table consistency. Native handles reclamation
        // may be delayed until appdomain shutdown.

        private const int InitialCapacity = 8;  // Initial length of the table. Must be a power of two.
        private readonly object _lock;          // This lock protects all mutation of data in the table.  Readers do not take this lock.
        private volatile Container _container;  // The actual storage for the table; swapped out as the table grows. [cDAC] [ConditionalWeakTable] : Contract depends on the exact names of this field and its type.
        private int _activeEnumeratorRefCount;  // The number of outstanding enumerators on the table

        public ConditionalWeakTable()
        {
            _lock = new object();
            _container = new Container(this);
        }

        /// <summary>Gets the value of the specified key.</summary>
        /// <param name="key">key of the value to find. Cannot be null.</param>
        /// <param name="value">
        /// If the key is found, contains the value associated with the key upon method return.
        /// If the key is not found, contains default(TValue).
        /// </param>
        /// <returns>Returns "true" if key was found, "false" otherwise.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public bool TryGetValue(TKey key, [MaybeNullWhen(false)] out TValue value)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            return _container.TryGetValueWorker(key, out value);
        }

        /// <summary>Adds a key to the table.</summary>
        /// <param name="key">key to add. May not be null.</param>
        /// <param name="value">value to associate with key.</param>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        /// <exception cref="ArgumentException"><paramref name="key"/> is already entered into the dictionary.</exception>
        public void Add(TKey key, TValue value)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            lock (_lock)
            {
                int entryIndex = _container.FindEntry(key, out _);
                if (entryIndex != -1)
                {
                    ThrowHelper.ThrowArgumentException(ExceptionResource.Argument_AddingDuplicate);
                }

                CreateEntry(key, value);
            }
        }

        /// <summary>Adds a key to the table if it doesn't already exist.</summary>
        /// <param name="key">The key to add.</param>
        /// <param name="value">The key's property value.</param>
        /// <returns>true if the key/value pair was added; false if the table already contained the key.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public bool TryAdd(TKey key, TValue value)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            lock (_lock)
            {
                int entryIndex = _container.FindEntry(key, out _);
                if (entryIndex != -1)
                {
                    return false;
                }

                CreateEntry(key, value);
                return true;
            }
        }

        /// <summary>Adds the key and value if the key doesn't exist, or updates the existing key's value if it does exist.</summary>
        /// <param name="key">key to add or update. May not be null.</param>
        /// <param name="value">value to associate with key.</param>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public void AddOrUpdate(TKey key, TValue value)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            lock (_lock)
            {
                int entryIndex = _container.FindEntry(key, out _);

                // if we found a key we should just update, if no we should create a new entry.
                if (entryIndex != -1)
                {
                    _container.UpdateValue(entryIndex, value);
                }
                else
                {
                    CreateEntry(key, value);
                }
            }
        }

        /// <summary>Removes a key and its value from the table.</summary>
        /// <param name="key">The key to remove.</param>
        /// <returns><see langword="true"/> if the key is found and removed; otherwise, <see langword="false"/>.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public bool Remove(TKey key)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            lock (_lock)
            {
                return _container.Remove(key, out _);
            }
        }

        /// <summary>Removes a key and its value from the table, and returns the removed value if it was present.</summary>
        /// <param name="key">The key to remove.</param>
        /// <param name="value">value removed from the table, if it was present.</param>
        /// <returns><see langword="true"/> if the key is found and removed; otherwise, <see langword="false"/>.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public bool Remove(TKey key, [MaybeNullWhen(false)] out TValue value)
        {
            if (key is null)
            {
                ThrowHelper.ThrowArgumentNullException(ExceptionArgument.key);
            }

            lock (_lock)
            {
                return _container.Remove(key, out value);
            }
        }

        /// <summary>Clear all the key/value pairs</summary>
        public void Clear()
        {
            lock (_lock)
            {
                // To clear, we would prefer to simply drop the existing container
                // and replace it with an empty one, as that's overall more efficient.
                // However, if there are any active enumerators, we don't want to do
                // that as it will end up removing all of the existing entries and
                // allowing new items to be added at the same indices when the container
                // is filled and replaced, and one of the guarantees we try to make with
                // enumeration is that new items added after enumeration starts won't be
                // included in the enumeration. As such, if there are active enumerators,
                // we simply use the container's removal functionality to remove all of the
                // keys; then when the table is resized, if there are still active enumerators,
                // these empty slots will be maintained.
                if (_activeEnumeratorRefCount > 0)
                {
                    _container.RemoveAllKeys();
                }
                else
                {
                    _container = new Container(this);
                }
            }
        }

        /// <summary>
        /// Searches for a specified key in the table and returns the corresponding value. If the key does
        /// not exist in the table, the method adds the given value and binds it to the specified key.
        /// </summary>
        /// <param name="key">The key of the value to find. It cannot be <see langword="null"/>.</param>
        /// <param name="value">The value to add and bind to <typeparamref name="TKey"/>, if one does not exist already.</param>
        /// <returns>The value bound to <typeparamref name="TKey"/> in the current <see cref="ConditionalWeakTable{TKey, TValue}"/> instance, after the method completes.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> is <see langword="null"/>.</exception>
        public TValue GetOrAdd(TKey key, TValue value)
        {
            // key is validated by TryGetValue
            if (TryGetValue(key, out TValue? existingValue))
            {
                return existingValue;
            }

            return GetOrAddLocked(key, value);
        }

        /// <summary>
        /// Searches for a specified key in the table and returns the corresponding value. If the key does not exist
        /// in the table, the method invokes the supplied factory to create a value that is bound to the specified key.
        /// </summary>
        /// <param name="key">The key of the value to find. It cannot be <see langword="null"/>.</param>
        /// <param name="valueFactory">The callback that creates a value for key, if one does not exist already. It cannot be <see langword="null"/>.</param>
        /// <returns>The value bound to <typeparamref name="TKey"/> in the current <see cref="ConditionalWeakTable{TKey, TValue}"/> instance, after the method completes.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> or <paramref name="valueFactory"/> are <see langword="null"/>.</exception>
        /// <remarks>
        /// If multiple threads try to initialize the same key, the table may invoke <paramref name="valueFactory"/> multiple times
        /// with the same key. Exactly one of these calls will succeed and the returned value of that call will be the one added to
        /// the table and returned by all the racing <see cref="GetOrAdd(TKey, Func{TKey, TValue})"/> calls. This rule permits the
        /// table to invoke <paramref name="valueFactory"/> outside the internal table lock, to prevent deadlocks.
        /// </remarks>
        public TValue GetOrAdd(TKey key, Func<TKey, TValue> valueFactory)
        {
            ArgumentNullException.ThrowIfNull(valueFactory);

            // key is validated by TryGetValue
            if (TryGetValue(key, out TValue? existingValue))
            {
                return existingValue;
            }

            // create the value outside of the lock
            TValue value = valueFactory(key);

            return GetOrAddLocked(key, value);
        }

        /// <summary>
        /// Searches for a specified key in the table and returns the corresponding value. If the key does not exist
        /// in the table, the method invokes the supplied factory to create a value that is bound to the specified key.
        /// </summary>
        /// <typeparam name="TArg">The type of the additional argument to use with the value factory.</typeparam>
        /// <param name="key">The key of the value to find. It cannot be <see langword="null"/>.</param>
        /// <param name="valueFactory">The callback that creates a value for key, if one does not exist already. It cannot be <see langword="null"/>.</param>
        /// <param name="factoryArgument">The additional argument to supply to <paramref name="valueFactory"/> upon invocation.</param>
        /// <returns>The value bound to <typeparamref name="TKey"/> in the current <see cref="ConditionalWeakTable{TKey, TValue}"/> instance, after the method completes.</returns>
        /// <exception cref="ArgumentNullException"><paramref name="key"/> or <paramref name="valueFactory"/> are <see langword="null"/>.</exception>
        /// <remarks>
        /// If multiple threads try to initialize the same key, the table may invoke <paramref name="valueFactory"/> multiple times with the
        /// same key. Exactly one of these calls will succeed and the returned value of that call will be the one added to the table and
        /// returned by all the racing <see cref="GetOrAdd{TArg}(TKey, Func{TKey, TArg, TValue}, TArg)"/> calls. This rule permits the
        /// table to invoke <paramref name="valueFactory"/> outside the internal table lock, to prevent deadlocks.
        /// </remarks>
        public TValue GetOrAdd<TArg>(TKey key, Func<TKey, TArg, TValue> valueFactory, TArg factoryArgument)
            where TArg : allows ref struct
        {
            ArgumentNullException.ThrowIfNull(valueFactory);

            // key is validated by TryGetValue
            if (TryGetValue(key, out TValue? existingValue))
            {
                return existingValue;
            }

            // create the value outside of the lock
            TValue value = valueFactory(key, factoryArgument);

            return GetOrAddLocked(key, value);
        }

        /// <summary>
        /// Searches for a specified key in the table and returns the corresponding value. If the key does not exist
        /// in the table, the method invokes a callback method to create a value that is bound to the specified key.
        /// </summary>
        /// <param name="key">key of the value to find. Cannot be null.</param>
        /// <param name="createValueCallback">callback that creates value for key. Cannot be null.</param>
        /// <returns></returns>
        /// <remarks>
        /// <para>
        /// If multiple threads try to initialize the same key, the table may invoke createValueCallback
        /// multiple times with the same key. Exactly one of these calls will succeed and the returned
        /// value of that call will be the one added to the table and returned by all the racing GetValue() calls.
        /// This rule permits the table to invoke createValueCallback outside the internal table lock
        /// to prevent deadlocks.
        /// </para>
        /// <para>
        /// Consider using <see cref="GetOrAdd(TKey, Func{TKey, TValue})"/> (or one of its overloads) instead.
        /// </para>
        /// </remarks>
        [EditorBrowsable(EditorBrowsableState.Never)]
        public TValue GetValue(TKey key, CreateValueCallback createValueCallback)
        {
            ArgumentNullException.ThrowIfNull(createValueCallback);

            // key is validated by TryGetValue
            if (TryGetValue(key, out TValue? existingValue))
            {
                return existingValue;
            }

            // create the value outside of the lock
            TValue value = createValueCallback(key);

            return GetOrAddLocked(key, value);
        }

        private TValue GetOrAddLocked(TKey key, TValue value)
        {
            lock (_lock)
            {
                // Now that we've taken the lock, must recheck in case we lost a race to add the key.
                if (_container.TryGetValueWorker(key, out TValue? existingValue))
                {
                    return existingValue;
                }
                else
                {
                    // Verified in-lock that we won the race to add the key. Add it now.
                    CreateEntry(key, value);
                    return value;
                }
            }
        }

        /// <summary>
        /// Helper method to call GetValue without passing a creation delegate.  Uses Activator.CreateInstance
        /// to create new instances as needed.  If TValue does not have a default constructor, this will throw.
        /// </summary>
        /// <param name="key">key of the value to find. Cannot be null.</param>
        /// <remarks>
        /// Consider using <see cref="GetOrAdd(TKey, Func{TKey, TValue})"/> (or one of its overloads) instead.
        /// </remarks>
        [EditorBrowsable(EditorBrowsableState.Never)]
        public TValue GetOrCreateValue(TKey key) => GetValue(key, _ => Activator.CreateInstance<TValue>());

        [EditorBrowsable(EditorBrowsableState.Never)]
        public delegate TValue CreateValueCallback(TKey key);

        /// <summary>Gets an enumerator for the table.</summary>
        /// <remarks>
        /// The returned enumerator will not extend the lifetime of
        /// any object pairs in the table, other than the one that's Current.  It will not return entries
        /// that have already been collected, nor will it return entries added after the enumerator was
        /// retrieved.  It may not return all entries that were present when the enumerat was retrieved,
        /// however, such as not returning entries that were collected or removed after the enumerator
        /// was retrieved but before they were enumerated.
        /// </remarks>
        IEnumerator<KeyValuePair<TKey, TValue>> IEnumerable<KeyValuePair<TKey, TValue>>.GetEnumerator()
        {
            lock (_lock)
            {
                Container c = _container;
                return c is null || c.FirstFreeEntry == 0 ?
                    GenericEmptyEnumerator<KeyValuePair<TKey, TValue>>.Instance :
                    new Enumerator(this);
            }
        }

        IEnumerator IEnumerable.GetEnumerator() => ((IEnumerable<KeyValuePair<TKey, TValue>>)this).GetEnumerator();

        /// <summary>Provides an enumerator for the table.</summary>
        private sealed class Enumerator : IEnumerator<KeyValuePair<TKey, TValue>>
        {
            // The enumerator would ideally hold a reference to the Container and the end index within that
            // container.  However, the safety of the CWT depends on the only reference to the Container being
            // from the CWT itself; the Container then employs a two-phase finalization scheme, where the first
            // phase nulls out that parent CWT's reference, guaranteeing that the second time it's finalized there
            // can be no other existing references to it in use that would allow for concurrent usage of the
            // native handles with finalization.  We would break that if we allowed this Enumerator to hold a
            // reference to the Container.  Instead, the Enumerator holds a reference to the CWT rather than to
            // the Container, and it maintains the CWT._activeEnumeratorRefCount field to track whether there
            // are outstanding enumerators that have yet to be disposed/finalized.  If there aren't any, the CWT
            // behaves as it normally does.  If there are, certain operations are affected, in particular resizes.
            // Normally when the CWT is resized, it enumerates the contents of the table looking for indices that
            // contain entries which have been collected or removed, and it frees those up, effectively moving
            // down all subsequent entries in the container (not in the existing container, but in a replacement).
            // This, however, would cause the enumerator's understanding of indices to break.  So, as long as
            // there is any outstanding enumerator, no compaction is performed.

            private ConditionalWeakTable<TKey, TValue>? _table; // parent table, set to null when disposed
            private readonly int _maxIndexInclusive;            // last index in the container that should be enumerated
            private int _currentIndex;                          // the current index into the container
            private KeyValuePair<TKey, TValue> _current;        // the current entry set by MoveNext and returned from Current

            public Enumerator(ConditionalWeakTable<TKey, TValue> table)
            {
                Debug.Assert(table != null, "Must provide a valid table");
                Debug.Assert(Monitor.IsEntered(table._lock), "Must hold the _lock lock to construct the enumerator");
                Debug.Assert(table._container != null, "Should not be used on a finalized table");
                Debug.Assert(table._container.FirstFreeEntry > 0, "Should have returned an empty enumerator instead");

                // Store a reference to the parent table and increase its active enumerator count.
                _table = table;
                Debug.Assert(table._activeEnumeratorRefCount >= 0, "Should never have a negative ref count before incrementing");
                table._activeEnumeratorRefCount++;

                // Store the max index to be enumerated.
                _maxIndexInclusive = table._container.FirstFreeEntry - 1;
                _currentIndex = -1;
            }

            ~Enumerator()
            {
                Dispose();
            }

            public void Dispose()
            {
                // Use an interlocked operation to ensure that only one thread can get access to
                // the _table for disposal and thus only decrement the ref count once.
                ConditionalWeakTable<TKey, TValue>? table = Interlocked.Exchange(ref _table, null);
                if (table != null)
                {
                    // Ensure we don't keep the last current alive unnecessarily
                    _current = default;

                    // Decrement the ref count that was incremented when constructed
                    lock (table._lock)
                    {
                        table._activeEnumeratorRefCount--;
                        Debug.Assert(table._activeEnumeratorRefCount >= 0, "Should never have a negative ref count after decrementing");
                    }

                    // Finalization is purely to decrement the ref count.  We can suppress it now.
                    GC.SuppressFinalize(this);
                }
            }

            public bool MoveNext()
            {
                // Start by getting the current table.  If it's already been disposed, it will be null.
                ConditionalWeakTable<TKey, TValue>? table = _table;
                if (table != null)
                {
                    // Once have the table, we need to lock to synchronize with other operations on
                    // the table, like adding.
                    lock (table._lock)
                    {
                        // From the table, we have to get the current container.  This could have changed
                        // since we grabbed the enumerator, but the index-to-pair mapping should not have
                        // due to there being at least one active enumerator.  If the table (or rather its
                        // container at the time) has already been finalized, this will be null.
                        Container c = table._container;
                        if (c != null)
                        {
                            // We have the container.  Find the next entry to return, if there is one.
                            // We need to loop as we may try to get an entry that's already been removed
                            // or collected, in which case we try again.
                            while (_currentIndex < _maxIndexInclusive)
                            {
                                _currentIndex++;
                                if (c.TryGetEntry(_currentIndex, out TKey? key, out TValue? value))
                                {
                                    _current = new KeyValuePair<TKey, TValue>(key, value);
                                    return true;
                                }
                            }
                        }
                    }
                }

                // Nothing more to enumerate.
                return false;
            }

            public KeyValuePair<TKey, TValue> Current
            {
                get
                {
                    if (_currentIndex < 0)
                    {
                        ThrowHelper.ThrowInvalidOperationException_InvalidOperation_EnumOpCantHappen();
                    }
                    return _current;
                }
            }

            object? IEnumerator.Current => Current;

            public void Reset() { }
        }

        /// <summary>Worker for adding a new key/value pair. Will resize the container if it is full.</summary>
        /// <param name="key"></param>
        /// <param name="value"></param>
        private void CreateEntry(TKey key, TValue value)
        {
            Debug.Assert(Monitor.IsEntered(_lock));
            Debug.Assert(key != null); // key already validated as non-null and not already in table.

            Container c = _container;
            if (!c.HasCapacity)
            {
                _container = c = c.Resize();
            }
            c.CreateEntryNoResize(key, value);
        }

        //--------------------------------------------------------------------------------------------
        // Entry can be in one of four states:
        //
        //    - Unused (stored with an index _firstFreeEntry and above)
        //         GetKey() == null
        //         hashCode == <dontcare>
        //         next == <dontcare>)
        //
        //    - Used with live key (linked into a bucket list where _buckets[hashCode & (_buckets.Length - 1)] points to first entry)
        //         GetKey() != null
        //         hashCode == RuntimeHelpers.GetHashCode(GetKey()) & int.MaxValue
        //         next links to next Entry in bucket.
        //
        //    - Used with dead key (linked into a bucket list where _buckets[hashCode & (_buckets.Length - 1)] points to first entry)
        //         GetKey() == null
        //         hashCode == <notcare>
        //         next links to next Entry in bucket.
        //
        //    - Has been removed from the table (by a call to Remove)
        //         GetKey() == <notcare>
        //         hashCode == -1
        //         next links to next Entry in bucket.
        //
        // The only difference between "used with live key" and "used with dead key" is that
        // GetKey() returns null. The transition from "used with live key" to "used with dead key"
        // happens asynchronously as a result of normal garbage collection. The dictionary itself
        // receives no notification when this happens.
        //
        // When the dictionary grows the _entries table, it scours it for expired keys and does not
        // add those to the new container.
        //  [cDAC] [ConditionalWeakTable] : Contract depends on the exact names of this type and the fields Pair, HashCode, and Next.
        //--------------------------------------------------------------------------------------------
        [StructLayout(LayoutKind.Auto)]
        private struct Entry
        {
#if CORECLR
            // The key and the value, held directly by this entry rather than by a per entry handle
            // or cell. The whole entries array of a container is registered with the GC once, which
            // is what gives these two slots their conditional semantics: the value is only kept
            // alive for as long as the key is reachable without going through the value.
            //
            // These slots are not object references as far as the GC descriptor of the entries
            // array is concerned, so they must only ever be touched through EphemeronArray, and the
            // entry must never be copied by value.
            public Ephemeron Pair;
#else
            public DependentHandle depHnd;      // Holds key and value using a weak reference for the key and a strong reference
                                                // for the value that is traversed only if the key is reachable without going through the value.
#endif
            public int HashCode;    // Cached copy of key's hashcode
            public int Next;        // Index of next entry, -1 if last

            /// <summary>Gets the key of this entry, or null if it is unused, expired or removed.</summary>
            public object? GetKey()
            {
#if CORECLR
                return EphemeronArray.GetKey(ref Pair);
#else
                return depHnd.IsAllocated ? depHnd.UnsafeGetTarget() : null;
#endif
            }

            /// <summary>Atomically gets the key and value of this entry.</summary>
            /// <remarks>This method requires <paramref name="value"/> to be on the stack to be properly tracked.</remarks>
            public object? GetKeyAndValue(out object? value)
            {
#if CORECLR
                return EphemeronArray.GetKeyAndValue(ref Pair, out value);
#else
                if (!depHnd.IsAllocated)
                {
                    value = null;
                    return null;
                }

                return depHnd.UnsafeGetTargetAndDependent(out value);
#endif
            }
        }

        /// <summary>
        /// Container holds the actual data for the table.  A given instance of Container always has the same capacity.  When we need
        /// more capacity, we create a new Container, copy the old one into the new one, and discard the old one.  This helps enable lock-free
        /// reads from the table, as readers never need to deal with motion of entries due to rehashing.
        /// </summary>
        private sealed class Container
        {
            private readonly ConditionalWeakTable<TKey, TValue> _parent;  // the ConditionalWeakTable with which this container is associated
            private int[] _buckets;                // _buckets[hashcode & (_buckets.Length - 1)] contains index of the first entry in bucket (-1 if empty). [cDAC] [ConditionalWeakTable] : Contract depends on this exact name
            private Entry[] _entries;              // the table entries containing the stored key/value pairs. [cDAC] [ConditionalWeakTable] : Contract depends on this exact name
            private int _firstFreeEntry;           // _firstFreeEntry < _entries.Length => table has capacity,  entries grow from the bottom of the table.
            private bool _invalid;                 // flag detects if OOM or other background exception threw us out of the lock.
            private readonly nint _entriesRegistration; // the GC's token for _entries, or 0 where entries describe themselves
#if !CORECLR
            private bool _finalized;               // set to true when initially finalized
            private volatile object? _oldKeepAlive; // used to ensure the next allocated container isn't finalized until this one is GC'd
#endif

            internal Container(ConditionalWeakTable<TKey, TValue> parent)
            {
                Debug.Assert(parent != null);
                Debug.Assert(BitOperations.IsPow2(InitialCapacity));

                const int Size = InitialCapacity;
                _buckets = new int[Size];
                for (int i = 0; i < _buckets.Length; i++)
                {
                    _buckets[i] = -1;
                }
                _entries = AllocateEntries(Size, out _entriesRegistration);

                // Only store the parent after all of the allocations have happened successfully.
                // Otherwise, as part of growing or clearing the container, we could end up allocating
                // a new Container that fails (OOMs) part way through construction but that gets finalized
                // and ends up clearing out some other container present in the associated CWT.
                _parent = parent;
            }

            private Container(ConditionalWeakTable<TKey, TValue> parent, int[] buckets, Entry[] entries, nint entriesRegistration, int firstFreeEntry)
            {
                Debug.Assert(parent != null);
                Debug.Assert(buckets != null);
                Debug.Assert(entries != null);
                Debug.Assert(buckets.Length == entries.Length);
                Debug.Assert(BitOperations.IsPow2(buckets.Length));

                _parent = parent;
                _buckets = buckets;
                _entries = entries;
                _entriesRegistration = entriesRegistration;
                _firstFreeEntry = firstFreeEntry;
            }

            /// <summary>Allocates the storage for a container's entries.</summary>
            /// <remarks>
            /// On CoreCLR every key/value pair of a container lives directly in this one array, which
            /// is registered with the GC as an ephemeron array. Registration happens here, before the
            /// array is published or any pair is stored into it: until it is registered the GC does
            /// not trace its pairs, so a value stored beforehand would simply be dropped. If the
            /// registration cannot be recorded this throws, and the half built container is
            /// discarded without ever having been reachable.
            /// </remarks>
            private static Entry[] AllocateEntries(int size, out nint entriesRegistration)
            {
                Entry[] entries = new Entry[size];
#if CORECLR
                ref Entry entry = ref MemoryMarshal.GetArrayDataReference(entries);
                int pairOffset = (int)Unsafe.ByteOffset(
                    ref Unsafe.As<Entry, byte>(ref entry),
                    ref Unsafe.As<Ephemeron, byte>(ref entry.Pair));

                entriesRegistration = EphemeronArray.Register(entries, pairOffset);
#else
                entriesRegistration = 0;
#endif
                return entries;
            }

            /// <summary>Stores a key/value pair into an entry that is not reachable by any reader yet.</summary>
            private static void InitializeEntry(ref Entry entry, nint entriesRegistration, object key, object? value)
            {
#if CORECLR
                EphemeronArray.SetKeyAndValue(entriesRegistration, ref entry.Pair, key, value);
#else
                _ = entriesRegistration;
                entry.depHnd = new DependentHandle(key, value);
#endif
            }

            internal bool HasCapacity => _firstFreeEntry < _entries.Length;

            internal int FirstFreeEntry => _firstFreeEntry;

            /// <summary>Worker for adding a new key/value pair. Container must NOT be full.</summary>
            internal void CreateEntryNoResize(TKey key, TValue value)
            {
                Debug.Assert(key != null); // key already validated as non-null and not already in table.
                Debug.Assert(HasCapacity);

                VerifyIntegrity();
                _invalid = true;

                int hashCode = RuntimeHelpers.GetHashCode(key) & int.MaxValue;
                int newEntry = _firstFreeEntry++;

                _entries[newEntry].HashCode = hashCode;
                InitializeEntry(ref _entries[newEntry], _entriesRegistration, key, value);
                int bucket = hashCode & (_buckets.Length - 1);
                _entries[newEntry].Next = _buckets[bucket];

                // This write must be volatile, as we may be racing with concurrent readers.  If they see
                // the new entry, they must also see all of the writes earlier in this method.
                Volatile.Write(ref _buckets[bucket], newEntry);

                _invalid = false;
            }

            /// <summary>Worker for finding a key/value pair. Must hold _lock.</summary>
            internal bool TryGetValueWorker(TKey key, [MaybeNullWhen(false)] out TValue value)
            {
                Debug.Assert(key != null); // Key already validated as non-null

                int entryIndex = FindEntry(key, out object? secondary);
                value = Unsafe.As<TValue>(secondary);
                return entryIndex != -1;
            }

            /// <summary>
            /// Returns -1 if not found (if key expires during FindEntry, this can be treated as "not found.").
            /// Must hold _lock, or be prepared to retry the search while holding _lock.
            /// </summary>
            /// <remarks>This method requires <paramref name="value"/> to be on the stack to be properly tracked.</remarks>
            internal int FindEntry(TKey key, out object? value)
            {
                Debug.Assert(key != null); // Key already validated as non-null.

                int hashCode = RuntimeHelpers.TryGetHashCode(key);

                if (hashCode == 0)
                {
                    // No hash code has been assigned to the key, so therefore it has not been added
                    // to any ConditionalWeakTable.
                    value = null;
                    return -1;
                }

                hashCode &= int.MaxValue;
                int bucket = hashCode & (_buckets.Length - 1);
                for (int entriesIndex = Volatile.Read(ref _buckets[bucket]); entriesIndex != -1; entriesIndex = _entries[entriesIndex].Next)
                {
                    if (_entries[entriesIndex].HashCode == hashCode && _entries[entriesIndex].GetKeyAndValue(out value) == key)
                    {
                        GC.KeepAlive(this); // Ensure we don't get finalized while accessing the entries

                        return entriesIndex;
                    }
                }

                GC.KeepAlive(this); // Ensure we don't get finalized while accessing the entries
                value = null;
                return -1;
            }

            /// <summary>Gets the entry at the specified entry index.</summary>
            internal bool TryGetEntry(int index, [NotNullWhen(true)] out TKey? key, [MaybeNullWhen(false)] out TValue value)
            {
                if (index < _entries.Length)
                {
                    object? oKey = _entries[index].GetKeyAndValue(out object? oValue);

                    GC.KeepAlive(this); // Ensure we don't get finalized while accessing the entries

                    if (oKey != null)
                    {
                        key = Unsafe.As<TKey>(oKey);
                        value = Unsafe.As<TValue>(oValue!);
                        return true;
                    }
                }

                key = default;
                value = default;
                return false;
            }

            /// <summary>Removes all of the keys in the table.</summary>
            internal void RemoveAllKeys()
            {
                for (int i = 0; i < _firstFreeEntry; i++)
                {
                    RemoveIndex(i);
                }
            }

            /// <summary>Removes the specified key from the table, if it exists.</summary>
            internal bool Remove(TKey key, [MaybeNullWhen(false)] out TValue value)
            {
                VerifyIntegrity();

                int entryIndex = FindEntry(key, out object? valueObject);
                if (entryIndex != -1)
                {
                    RemoveIndex(entryIndex);
                    value = Unsafe.As<TValue>(valueObject!);
                    return true;
                }

                value = null;
                return false;
            }

            private void RemoveIndex(int entryIndex)
            {
                Debug.Assert(entryIndex >= 0 && entryIndex < _firstFreeEntry);

                ref Entry entry = ref _entries[entryIndex];

                // We do not free the entry here, as we may be racing with readers who already saw the hash code.
                // Instead, we simply overwrite the entry's hash code, so subsequent reads will ignore it.
                // Native handles are free'd in Container's finalizer, after the table is resized or discarded;
                // pairs held directly by the entries array are reclaimed with the array itself.
                Volatile.Write(ref entry.HashCode, -1);

                // Also, clear the key to allow GC to collect objects pointed to by the entry
                RetireEntry(ref entry);
            }

            /// <summary>Permanently clears the key and the value of an entry.</summary>
            private static void RetireEntry(ref Entry entry)
            {
#if CORECLR
                // Storing null needs no registration token: a null slot references nothing, so it can
                // never make an array interesting to a collection that would otherwise skip it.
                EphemeronArray.Retire(ref entry.Pair);
#else
                entry.depHnd.UnsafeSetTargetToNull();
#endif
            }

            internal void UpdateValue(int entryIndex, TValue newValue)
            {
                Debug.Assert(entryIndex != -1);

                VerifyIntegrity();
                _invalid = true;

#if CORECLR
                EphemeronArray.SetValue(_entriesRegistration, ref _entries[entryIndex].Pair, newValue);
#else
                _entries[entryIndex].depHnd.UnsafeSetDependent(newValue);
#endif

                _invalid = false;
            }

            /// <summary>Resize, and scrub expired keys off bucket lists. Must hold _lock.</summary>
            /// <remarks>
            /// _firstEntry is less than _entries.Length on exit, that is, the table has at least one free entry.
            /// </remarks>
            internal Container Resize()
            {
                Debug.Assert(!HasCapacity);

                bool hasExpiredEntries = false;
                int newSize = _buckets.Length;

                if (_parent is null || _parent._activeEnumeratorRefCount == 0)
                {
                    // If any expired or removed keys exist, we won't resize.
                    // If there any active enumerators, though, we don't want
                    // to compact and thus have no expired entries.
                    for (int entriesIndex = 0; entriesIndex < _entries.Length; entriesIndex++)
                    {
                        ref Entry entry = ref _entries[entriesIndex];

                        if (entry.HashCode == -1)
                        {
                            // the entry was removed
                            hasExpiredEntries = true;
                            break;
                        }

                        if (entry.GetKey() is null)
                        {
                            // the entry has expired
                            hasExpiredEntries = true;
                            break;
                        }
                    }
                }

                if (!hasExpiredEntries)
                {
                    // Not necessary to check for overflow here, the attempt to allocate new arrays will throw
                    newSize = _buckets.Length * 2;
                }

                return Resize(newSize);
            }

            internal Container Resize(int newSize)
            {
                Debug.Assert(newSize >= _buckets.Length);
                Debug.Assert(BitOperations.IsPow2(newSize));

                // Reallocate both buckets and entries and rebuild the bucket and entries from scratch.
                // This serves both to scrub entries with expired keys and to put the new entries in the proper bucket.
                int[] newBuckets = new int[newSize];
                for (int bucketIndex = 0; bucketIndex < newBuckets.Length; bucketIndex++)
                {
                    newBuckets[bucketIndex] = -1;
                }
                Entry[] newEntries = AllocateEntries(newSize, out nint newEntriesRegistration);
                int newEntriesIndex = 0;
                bool activeEnumerators = _parent != null && _parent._activeEnumeratorRefCount > 0;
#if !CORECLR
                bool transferredHandles;
#endif

                // Migrate existing entries to the new table.
                if (activeEnumerators)
                {
#if !CORECLR
                    transferredHandles = true;
#endif

                    // There's at least one active enumerator, which means we don't want to
                    // remove any expired/removed entries, in order to not affect existing
                    // entries indices.  Copy over the entries while rebuilding the buckets list,
                    // as the buckets are dependent on the buckets list length, which is changing.
                    for (; newEntriesIndex < _entries.Length; newEntriesIndex++)
                    {
                        ref Entry oldEntry = ref _entries[newEntriesIndex];
                        ref Entry newEntry = ref newEntries[newEntriesIndex];
                        int hashCode = oldEntry.HashCode;

                        newEntry.HashCode = hashCode;
                        TransferEntry(ref oldEntry, ref newEntry, newEntriesRegistration);
                        int bucket = hashCode & (newBuckets.Length - 1);
                        newEntry.Next = newBuckets[bucket];
                        newBuckets[bucket] = newEntriesIndex;
                    }
                }
                else
                {
#if !CORECLR
                    transferredHandles = false;
#endif

                    // There are no active enumerators, which means we want to compact by
                    // removing expired/removed entries.
                    for (int entriesIndex = 0; entriesIndex < _entries.Length; entriesIndex++)
                    {
                        ref Entry oldEntry = ref _entries[entriesIndex];
                        int hashCode = oldEntry.HashCode;
                        if (hashCode != -1)
                        {
                            if (oldEntry.GetKey() is not null)
                            {
#if !CORECLR
                                transferredHandles = true;
#endif

                                ref Entry newEntry = ref newEntries[newEntriesIndex];

                                // Entry is used and has not expired. Link it into the appropriate bucket list.
                                newEntry.HashCode = hashCode;
                                TransferEntry(ref oldEntry, ref newEntry, newEntriesRegistration);
                                int bucket = hashCode & (newBuckets.Length - 1);
                                newEntry.Next = newBuckets[bucket];
                                newBuckets[bucket] = newEntriesIndex;
                                newEntriesIndex++;
                            }
                            else
                            {
                                // Pretend the item was removed, so that this container's finalizer
                                // will clean up this dependent handle.
                                Volatile.Write(ref oldEntry.HashCode, -1);
                            }
                        }
                    }
                }

                // Create the new container.  We want to transfer the responsibility of freeing the handles from
                // the old container to the new container, and also ensure that the new container isn't finalized
                // while the old container may still be in use.  As such, we store a reference from the old container
                // to the new one, which will keep the new container alive as long as the old one is.
                var newContainer = new Container(_parent!, newBuckets, newEntries, newEntriesRegistration, newEntriesIndex);
#if !CORECLR
                if (activeEnumerators)
                {
                    // If there are active enumerators, both the old container and the new container may be storing
                    // the same entries with -1 hash codes, which the finalizer will clean up even if the container
                    // is not the active container for the table.  To prevent that, we want to stop the old container
                    // from being finalized, as it no longer has any responsibility for any cleanup.
                    GC.SuppressFinalize(this);
                }

                if (transferredHandles)
                {
                    // Once this is set, the old container's finalizer will not free transferred dependent handles,
                    // and the new container's finalizer can't be run until this container is no longer in use.
                    _oldKeepAlive = newContainer;
                }
#endif

                GC.KeepAlive(this); // ensure we don't get finalized while accessing the entries.

                return newContainer;
            }

            /// <summary>Moves the key/value pair of an entry into an entry of the replacement container.</summary>
            /// <remarks>
            /// On CoreCLR the pair is copied rather than handed over, because it lives directly in the
            /// container's own entries array. The copy goes through real object references, so it is
            /// safe against a collection happening in the middle of the migration and against the
            /// destination array being relocated; the cost is that a key that is already unreachable
            /// but not yet collected survives one more collection. The destination array is registered
            /// but not published yet, so the intermediate "key without value" state is not observable.
            /// </remarks>
            private static void TransferEntry(ref Entry oldEntry, ref Entry newEntry, nint newEntriesRegistration)
            {
#if CORECLR
                object? key = EphemeronArray.GetKeyAndValue(ref oldEntry.Pair, out object? value);

                if (key is not null)
                {
                    EphemeronArray.SetKeyAndValue(newEntriesRegistration, ref newEntry.Pair, key, value);
                }
#else
                _ = newEntriesRegistration;
                newEntry.depHnd = oldEntry.depHnd;
#endif
            }

            private void VerifyIntegrity()
            {
                if (_invalid)
                {
                    throw new InvalidOperationException(SR.InvalidOperation_CollectionCorrupted);
                }
            }

#if !CORECLR
            // On CoreCLR the entries hold their key/value pairs directly, in one array that is
            // registered with the GC, so a container owns nothing that has to be released and needs
            // no finalizer at all. That also means retired containers do not have to be kept alive
            // by _oldKeepAlive (see Resize), which would otherwise keep a chain of replaced
            // containers reachable.
            ~Container()
            {
                // Skip doing anything if the container is invalid, including if somehow
                // the container object was allocated but its associated table never set.
                if (_invalid || _parent is null)
                {
                    return;
                }

                // It's possible that the ConditionalWeakTable could have been resurrected, in which case code could
                // be accessing this Container as it's being finalized.  We don't support usage after finalization,
                // but we also don't want to potentially corrupt state by allowing dependency handles to be used as
                // or after they've been freed.  To avoid that, if it's at all possible that another thread has a
                // reference to this container via the CWT, we remove such a reference and then re-register for
                // finalization: the next time around, we can be sure that no references remain to this and we can
                // clean up the dependency handles without fear of corruption.
                if (!_finalized)
                {
                    _finalized = true;
                    lock (_parent._lock)
                    {
                        if (_parent._container == this)
                        {
                            _parent._container = null!;
                        }
                    }
                    GC.ReRegisterForFinalize(this); // next time it's finalized, we'll be sure there are no remaining refs
                    return;
                }

                Entry[] entries = _entries;
                _invalid = true;
                _entries = null!;
                _buckets = null!;

                if (entries != null)
                {
                    for (int entriesIndex = 0; entriesIndex < entries.Length; entriesIndex++)
                    {
                        // We need to free handles in two cases:
                        // - If this container still owns the dependency handle (meaning ownership hasn't been transferred
                        //   to another container that replaced this one), then it should be freed.
                        // - If this container had the entry removed, then even if in general ownership was transferred to
                        //   another container, removed entries are not, therefore this container must free them.
                        if (_oldKeepAlive is null || entries[entriesIndex].HashCode == -1)
                        {
                            entries[entriesIndex].depHnd.Dispose();
                        }
                    }
                }
            }
#endif // !CORECLR
        }
    }
}
