// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#ifndef STANDARD_WRITE_BARRIER_TEST_H
#define STANDARD_WRITE_BARRIER_TEST_H

#ifdef FEATURE_WRITE_BARRIER_STANDARD_ABI_TEST

uint8_t* GetWriteBarrierTestMetadataBase();
WriteBarrierSlowPath GetWriteBarrierTestSlowPath();

#endif

#endif
