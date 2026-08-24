// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Diagnostics;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace System
{
    public partial class Buffer
    {
        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern unsafe void BulkMoveWithOldValueWriteBarrierInternal(
            ref byte destination,
            ref byte source,
            MethodTable* type,
            nuint elementSize,
            nuint elementCount);

        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern void BulkMoveWithWriteBarrierInternal(ref byte destination, ref byte source, nuint byteCount);

        [MethodImpl(MethodImplOptions.InternalCall)]
        private static extern unsafe void ClearWithOldValueWriteBarrierInternal(
            ref byte destination,
            MethodTable* type,
            nuint elementSize,
            nuint elementCount);

        internal static unsafe void BulkMoveWithOldValueWriteBarrier(
            ref byte destination,
            ref byte source,
            MethodTable* type,
            nuint elementSize,
            nuint elementCount)
        {
            Debug.Assert(elementSize != 0);
            Debug.Assert(elementCount <= (nuint.MaxValue / elementSize));

            nuint totalByteCount = elementSize * elementCount;
            if ((totalByteCount == 0) || Unsafe.AreSame(ref destination, ref source))
            {
                return;
            }

            nuint elementsPerChunk = BulkMoveWithWriteBarrierChunk / elementSize;
            if (elementsPerChunk == 0)
            {
                elementsPerChunk = 1;
            }

            if ((nuint)(nint)Unsafe.ByteOffset(ref source, ref destination) >= totalByteCount)
            {
                nuint processed = 0;
                while (processed < elementCount)
                {
                    nuint chunk = Math.Min(elementsPerChunk, elementCount - processed);
                    nuint byteOffset = processed * elementSize;
                    BulkMoveWithOldValueWriteBarrierInternal(
                        ref Unsafe.AddByteOffset(ref destination, byteOffset),
                        ref Unsafe.AddByteOffset(ref source, byteOffset),
                        type,
                        elementSize,
                        chunk);
                    processed += chunk;
                    Thread.FastPollGC();
                }
            }
            else
            {
                nuint remaining = elementCount;
                while (remaining != 0)
                {
                    nuint chunk = Math.Min(elementsPerChunk, remaining);
                    remaining -= chunk;
                    nuint byteOffset = remaining * elementSize;
                    BulkMoveWithOldValueWriteBarrierInternal(
                        ref Unsafe.AddByteOffset(ref destination, byteOffset),
                        ref Unsafe.AddByteOffset(ref source, byteOffset),
                        type,
                        elementSize,
                        chunk);
                    Thread.FastPollGC();
                }
            }
        }

        internal static unsafe void ClearWithOldValueWriteBarrier(
            ref byte destination,
            MethodTable* type,
            nuint elementSize,
            nuint elementCount)
        {
            Debug.Assert(elementSize != 0);
            Debug.Assert(elementCount <= (nuint.MaxValue / elementSize));

            nuint elementsPerChunk = BulkMoveWithWriteBarrierChunk / elementSize;
            if (elementsPerChunk == 0)
            {
                elementsPerChunk = 1;
            }

            nuint processed = 0;
            while (processed < elementCount)
            {
                nuint chunk = Math.Min(elementsPerChunk, elementCount - processed);
                ClearWithOldValueWriteBarrierInternal(
                    ref Unsafe.AddByteOffset(ref destination, processed * elementSize),
                    type,
                    elementSize,
                    chunk);
                processed += chunk;
                Thread.FastPollGC();
            }
        }

        // Used by ilmarshalers.cpp
        internal static unsafe void Memcpy(byte* dest, byte* src, int len)
        {
            Debug.Assert(len >= 0, "Negative length in memcpy!");
            Memmove(ref *dest, ref *src, (nuint)(uint)len /* force zero-extension */);
        }

        // Used by ilmarshalers.cpp
        internal static unsafe void Memcpy(byte* pDest, int destIndex, byte[] src, int srcIndex, int len)
        {
            Debug.Assert((srcIndex >= 0) && (destIndex >= 0) && (len >= 0), "Index and length must be non-negative!");
            Debug.Assert(src.Length - srcIndex >= len, "not enough bytes in src");

            Memmove(ref *(pDest + (uint)destIndex), ref Unsafe.Add(ref MemoryMarshal.GetArrayDataReference(src), (nint)(uint)srcIndex /* force zero-extension */), (uint)len);
        }
    }
}
