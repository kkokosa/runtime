// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

namespace System.Runtime
{
    /// <summary>
    /// Represents a dependent GC handle, which will conditionally keep a dependent object instance alive as long as
    /// a target object instance is alive as well, without representing a strong reference to the target instance.
    /// </summary>
    /// <remarks>
    /// A <see cref="DependentHandle"/> value with a given object instance as target will not cause the target
    /// to be kept alive if there are no other strong references to it, but it will do so for the dependent
    /// object instance as long as the target is alive.
    /// <para>
    /// Using this type is conceptually equivalent to having a weak reference to a given target object instance A,
    /// with that object having a field or property (or some other strong reference) to a dependent object instance B.
    /// </para>
    /// <para>
    /// The <see cref="DependentHandle"/> type is not thread-safe, and consumers are responsible for ensuring that
    /// <see cref="Dispose"/> is not called concurrently with other APIs. Not doing so results in undefined behavior.
    /// </para>
    /// <para>
    /// The <see cref="IsAllocated"/>, <see cref="Target"/>, <see cref="Dependent"/> and <see cref="TargetAndDependent"/>
    /// properties are instead thread-safe, and safe to use if <see cref="Dispose"/> is not concurrently invoked as well.
    /// </para>
    /// </remarks>
    public partial struct DependentHandle : IDisposable
    {
        // =========================================================================================
        // A DependentHandle is backed by a one element registered ephemeron array rather than by a
        // native GC handle, so there is no unmanaged resource to release and no handle table entry
        // that could be leaked. The registration is weak: once the array becomes unreachable the GC
        // reclaims it and drops the registration along with it.
        //
        // DependentHandles exist in one of two states:
        //
        //    IsAllocated == false
        //        No array is referenced. Illegal to get Target, Dependent or TargetAndDependent.
        //        Ok to call Dispose().
        //
        //        Initializing a DependentHandle using the nullary ctor creates a DependentHandle
        //        that's in the !IsAllocated state.
        //
        //    IsAllocated == true
        //        An array is referenced. Calling Dispose() drops the reference; the array is then
        //        reclaimed like any other unreachable object.
        //
        // This struct intentionally does no self-synchronization. It's up to the caller to
        // to use DependentHandles in a thread-safe way.
        // =========================================================================================

        private Ephemeron[]? _data;

        // The token the GC hands out at registration. It is what tells a collection that condemns
        // only the younger generations that this array may now reference a young object, and it is
        // only meaningful while _data is non null.
        private nint _registration;

        /// <summary>
        /// Initializes a new instance of the <see cref="DependentHandle"/> struct with the specified arguments.
        /// </summary>
        /// <param name="target">The target object instance to track.</param>
        /// <param name="dependent">The dependent object instance to associate with <paramref name="target"/>.</param>
        public DependentHandle(object? target, object? dependent)
        {
            Ephemeron[] data = new Ephemeron[1];

            // The array has to be registered before anything is stored into it: until then the GC
            // does not trace its pair at all, so a dependent stored first would simply be dropped.
            _registration = EphemeronArray.Register(data, pairOffset: 0);

            EphemeronArray.SetKeyAndValue(_registration, ref data[0], target, dependent);

            _data = data;
        }

        /// <summary>
        /// Gets a value indicating whether this instance was constructed with
        /// <see cref="DependentHandle(object?, object?)"/> and has not yet been disposed.
        /// </summary>
        /// <remarks>This property is thread-safe.</remarks>
        public readonly bool IsAllocated => _data is not null;

        /// <summary>
        /// Gets or sets the target object instance for the current handle. The target can only be set to a <see langword="null"/> value
        /// once the <see cref="DependentHandle"/> instance has been created. Doing so will cause <see cref="Dependent"/> to start
        /// returning <see langword="null"/> as well, and to become eligible for collection even if the previous target is still alive.
        /// </summary>
        /// <exception cref="InvalidOperationException">
        /// Thrown if <see cref="IsAllocated"/> is <see langword="false"/> or if the input value is not <see langword="null"/>.</exception>
        /// <remarks>This property is thread-safe.</remarks>
        public object? Target
        {
            readonly get
            {
                Ephemeron[]? data = _data;

                if (data is null)
                {
                    ThrowHelper.ThrowInvalidOperationException();
                }

                return EphemeronArray.GetKey(ref data[0]);
            }
            set
            {
                Ephemeron[]? data = _data;

                if (data is null || value is not null)
                {
                    ThrowHelper.ThrowInvalidOperationException();
                }

                EphemeronArray.Retire(ref data[0]);
            }
        }

        /// <summary>
        /// Gets or sets the dependent object instance for the current handle.
        /// </summary>
        /// <remarks>
        /// If it is needed to retrieve both <see cref="Target"/> and <see cref="Dependent"/>, it is necessary
        /// to ensure that the returned instance from <see cref="Target"/> will be kept alive until <see cref="Dependent"/>
        /// is retrieved as well, or it might be collected and result in unexpected behavior. This can be done by storing the
        /// target in a local and calling <see cref="GC.KeepAlive(object)"/> on it after <see cref="Dependent"/> is accessed.
        /// </remarks>
        /// <exception cref="InvalidOperationException">Thrown if <see cref="IsAllocated"/> is <see langword="false"/>.</exception>
        public object? Dependent
        {
            readonly get
            {
                Ephemeron[]? data = _data;

                if (data is null)
                {
                    ThrowHelper.ThrowInvalidOperationException();
                }

                EphemeronArray.GetKeyAndValue(ref data[0], out object? dependent);

                return dependent;
            }
            set
            {
                Ephemeron[]? data = _data;

                if (data is null)
                {
                    ThrowHelper.ThrowInvalidOperationException();
                }

                EphemeronArray.SetValue(_registration, ref data[0], value);
            }
        }

        /// <summary>
        /// Gets the values of both <see cref="Target"/> and <see cref="Dependent"/> (if available) as an atomic operation.
        /// That is, even if <see cref="Target"/> is concurrently set to <see langword="null"/>, calling this method
        /// will either return <see langword="null"/> for both target and dependent, or return both previous values.
        /// If <see cref="Target"/> and <see cref="Dependent"/> were used sequentially in this scenario instead, it
        /// would be possible to sometimes successfully retrieve the previous target, but then fail to get the dependent.
        /// </summary>
        /// <returns>The values of <see cref="Target"/> and <see cref="Dependent"/>.</returns>
        /// <exception cref="InvalidOperationException">Thrown if <see cref="IsAllocated"/> is <see langword="false"/>.</exception>
        /// <remarks>This property is thread-safe.</remarks>
        public readonly (object? Target, object? Dependent) TargetAndDependent
        {
            get
            {
                Ephemeron[]? data = _data;

                if (data is null)
                {
                    ThrowHelper.ThrowInvalidOperationException();
                }

                object? target = EphemeronArray.GetKeyAndValue(ref data[0], out object? dependent);

                return (target, dependent);
            }
        }

        /// <summary>
        /// Gets the target object instance for the current handle.
        /// </summary>
        /// <returns>The target object instance, if present.</returns>
        /// <remarks>This method mirrors <see cref="Target"/>, but without the allocation check.</remarks>
        internal readonly object? UnsafeGetTarget()
        {
            return EphemeronArray.GetKey(ref _data![0]);
        }

        /// <summary>
        /// Atomically retrieves the values of both <see cref="Target"/> and <see cref="Dependent"/>, if available.
        /// </summary>
        /// <param name="dependent">The dependent instance, if available.</param>
        /// <returns>The values of <see cref="Target"/> and <see cref="Dependent"/>.</returns>
        /// <remarks>
        /// This method mirrors the <see cref="TargetAndDependent"/> property, but without the allocation check.
        /// Note that <paramref name="dependent"/> is required to be on the stack (or it might not be tracked).
        /// </remarks>
        internal readonly object? UnsafeGetTargetAndDependent(out object? dependent)
        {
            return EphemeronArray.GetKeyAndValue(ref _data![0], out dependent);
        }

        /// <summary>
        /// Sets the target object instance for the current handle to <see langword="null"/>.
        /// </summary>
        /// <remarks>This method mirrors the <see cref="Target"/> setter, but without allocation and input checks.</remarks>
        internal readonly void UnsafeSetTargetToNull()
        {
            EphemeronArray.Retire(ref _data![0]);
        }

        /// <summary>
        /// Sets the dependent object instance for the current handle.
        /// </summary>
        /// <remarks>This method mirrors <see cref="Dependent"/>, but without the allocation check.</remarks>
        internal readonly void UnsafeSetDependent(object? dependent)
        {
            EphemeronArray.SetValue(_registration, ref _data![0], dependent);
        }

        /// <inheritdoc cref="IDisposable.Dispose"/>
        /// <remarks>This method is not thread-safe.</remarks>
        public void Dispose()
        {
            // Forces the DependentHandle back to non-allocated state (if not already there).
            Ephemeron[]? data = _data;

            if (data is not null)
            {
                nint registration = _registration;
                _data = null;
                _registration = 0;

                // Retire the pair eagerly, so that a dependent kept alive only by this handle becomes
                // collectible at the next GC even if a racing reader still holds the array alive.
                EphemeronArray.Retire(ref data[0]);
                EphemeronArray.Unregister(data, registration);
            }
        }
    }
}
