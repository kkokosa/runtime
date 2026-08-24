// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.
//
// File: ephemeronarray.h
//

//
// FCalls for System.Runtime.EphemeronArray
//

#ifndef __EPHEMERONARRAY_H__
#define __EPHEMERONARRAY_H__

#include "fcall.h"

// A registered ephemeron array is an ordinary managed array whose element type contains no object
// reference fields as far as its GC descriptor is concerned, but which holds pairs of raw object
// pointers - a key and a value - that the GC treats the way it treats a dependent handle: the value
// is only promoted while the key is reachable by other means, and the pair is severed when it is
// not.
//
// Registration is what makes those pairs visible to the GC at all, so it has to happen before the
// array is published to anything else and before any pair is stored into it.
//
// See IGCHeap::RegisterEphemeronArray for the contract, and System.Runtime.EphemeronArray for the
// managed side.
class EphemeronArrayNative
{
public:
    FCDECL2(static void*, Register, ArrayBase* array, INT32 pairOffset);
    FCDECL2(static void, Unregister, ArrayBase* array, void* registration);
};

#endif // __EPHEMERONARRAY_H__
