// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace System.Runtime
{
    /// <summary>
    /// A single conditional key/value pair inside a registered ephemeron array.
    /// </summary>
    /// <remarks>
    /// The two slots are declared as <see cref="IntPtr"/> rather than as object references on
    /// purpose: the GC descriptor of an array of this type - or of any type embedding it - must not
    /// describe them, or the generic marking, card marking, relocation and heap verification paths
    /// would trace them strongly and the value would keep its own key alive forever.
    /// <para>
    /// Nothing outside <see cref="EphemeronArray"/> may read or write these fields, and an
    /// <see cref="Ephemeron"/> must never be copied by value: a copy of a slot in a local or in an
    /// unregistered location is a raw pointer that no longer participates in relocation and that
    /// the next compacting collection turns into a dangling reference. Always access a pair through
    /// a <see langword="ref"/> to the array element it lives in.
    /// </para>
    /// </remarks>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Ephemeron
    {
        internal nint Key;
        internal nint Value;
    }

    /// <summary>
    /// The managed side of the GC's registered ephemeron arrays: arrays that hold
    /// <see cref="Ephemeron"/> pairs whose value is only kept alive for as long as the key is
    /// reachable without going through the value.
    /// </summary>
    /// <remarks>
    /// An array has to be registered with <see cref="Register"/> before any pair is stored into it
    /// and before it is published anywhere another thread could reach it. Until it is registered
    /// the GC knows nothing about its pairs, so a value stored into it would simply not be traced.
    /// <para>
    /// The registration is weak. It does not keep the array alive: the collection that reclaims
    /// the array also drops the registration. Storage with an explicit lifetime may unregister
    /// after clearing all of its pairs.
    /// </para>
    /// </remarks>
    internal static unsafe class EphemeronArray
    {
        /// <summary>
        /// Registers <paramref name="array"/> with the GC and returns the token that
        /// <see cref="MarkMutated"/> needs.
        /// </summary>
        /// <param name="array">
        /// The array holding the pairs. Its element type must not contain object reference fields.
        /// </param>
        /// <param name="pairOffset">The byte offset of the pair within an element.</param>
        /// <exception cref="OutOfMemoryException">The registration could not be recorded.</exception>
        internal static nint Register(Array array, int pairOffset)
        {
            Debug.Assert(array is not null);
            Debug.Assert(pairOffset >= 0);

            byte* registration = RegisterCore(array, pairOffset);

            if (registration is null)
            {
                // The array is unusable as ephemeron storage: its pairs would never be traced.
                // Fail here rather than let the caller publish storage that silently loses values.
                throw new OutOfMemoryException();
            }

            return (nint)registration;
        }

        /// <summary>Removes the registration of an array that will no longer store ephemeron pairs.</summary>
        internal static void Unregister(Array array, nint registration)
        {
            Debug.Assert(registration != 0);

            UnregisterCore(array, (byte*)registration);
        }

        /// <summary>
        /// Tells the GC that a key or a value that may be younger than the array is about to be
        /// stored into it.
        /// </summary>
        /// <remarks>
        /// Without this a collection that condemns only the younger generations is free to skip an
        /// array whose pairs used to reference nothing but old objects, which would leave a
        /// reference to a collected object behind. It must therefore happen <em>before</em> the
        /// store it covers; the release semantics of the write below also keep the JIT from moving
        /// it after one.
        /// <para>
        /// Storing <see langword="null"/> needs no call: a null slot references nothing, so it can
        /// never make an array interesting to a collection that would otherwise skip it.
        /// </para>
        /// </remarks>
        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        internal static void MarkMutated(nint registration)
        {
            Debug.Assert(registration != 0);

            Volatile.Write(ref *(byte*)registration, 0);
        }

        /// <summary>Reads the key of a pair.</summary>
        internal static object? GetKey(ref Ephemeron pair) =>
            Volatile.Read(ref Unsafe.As<nint, object?>(ref pair.Key));

        /// <summary>
        /// Reads a consistent key/value pair, returning <see langword="null"/> for both if the pair
        /// has been severed or retired.
        /// </summary>
        /// <remarks>
        /// The GC clears the key before the value, and so does <see cref="Retire"/>. Reading the
        /// key, then the value, then re-reading the key means that a non null result necessarily
        /// kept the key alive across the read of the value, so the pair cannot have been severed in
        /// between and the two values belong together.
        /// </remarks>
        internal static object? GetKeyAndValue(ref Ephemeron pair, out object? value)
        {
            object? key = Volatile.Read(ref Unsafe.As<nint, object?>(ref pair.Key));

            if (key is null)
            {
                value = null;
                return null;
            }

            value = Volatile.Read(ref Unsafe.As<nint, object?>(ref pair.Value));

            if (Volatile.Read(ref Unsafe.As<nint, object?>(ref pair.Key)) is null)
            {
                value = null;
                return null;
            }

            return key;
        }

        /// <summary>Initializes a pair that no other thread can observe yet.</summary>
        /// <remarks>
        /// The key is published before the value, which is what makes this safe against a
        /// collection running in the middle: the GC clears the value of any pair whose key is null,
        /// so storing the value first would let a collection that runs between the two writes throw
        /// it away. With the key first the worst a collection can see is a live key - the caller is
        /// holding it - whose value has not been stored yet, which needs no work from the GC. The
        /// resulting "key without value" state is never observable, because the caller has not
        /// published the pair yet.
        /// </remarks>
        internal static void SetKeyAndValue(nint registration, ref Ephemeron pair, object? key, object? value)
        {
            MarkMutated(registration);

            Volatile.Write(ref Unsafe.As<nint, object?>(ref pair.Key), key);
            Volatile.Write(ref Unsafe.As<nint, object?>(ref pair.Value), value);
        }

        /// <summary>Replaces the value of a pair.</summary>
        internal static void SetValue(nint registration, ref Ephemeron pair, object? value)
        {
            MarkMutated(registration);

            Volatile.Write(ref Unsafe.As<nint, object?>(ref pair.Value), value);
        }

        /// <summary>Permanently retires a pair.</summary>
        /// <remarks>
        /// The key is cleared first for the reason given on <see cref="GetKeyAndValue"/>. The GC
        /// also clears the value of any pair it finds with a null key, so the window between the
        /// two writes cannot leave a value tracked on its own.
        /// </remarks>
        internal static void Retire(ref Ephemeron pair)
        {
            Volatile.Write(ref Unsafe.As<nint, object?>(ref pair.Key), null);
            Volatile.Write(ref Unsafe.As<nint, object?>(ref pair.Value), null);
        }

        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern byte* RegisterCore(Array array, int pairOffset);

        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern void UnregisterCore(Array array, byte* registration);
    }
}
