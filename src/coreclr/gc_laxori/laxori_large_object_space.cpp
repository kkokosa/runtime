// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

#include "common.h"
#include "gcenv.h"
#include "laxori_large_object_space.h"
#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
#include "laxori_completion_counter.h"
#endif

#include <new>
#ifndef LAXORI_SIDE_METADATA_TEST_PLATFORM
#include <minipal/ospagesize.h>
#endif

LaxoriLargeObjectSpace::LaxoriLargeObjectSpace()
    : m_metadata(nullptr)
    , m_reservation(nullptr)
    , m_reservation_bytes(0)
    , m_owns_reservation(false)
    , m_free_spans(nullptr)
    , m_active_spans(nullptr)
    , m_quarantined_spans(nullptr)
    , m_phase(LaxoriLargeObjectPhase::Shutdown)
    , m_mark_state(0)
{
}

LaxoriLargeObjectSpace::~LaxoriLargeObjectSpace()
{
    Shutdown();
}

size_t LaxoriLargeObjectSpace::GetCommittedBytes() const
{
    return m_span_bytes.load(std::memory_order_acquire);
}

bool LaxoriLargeObjectSpace::ShouldUseLargeObjectSpace(size_t objectBytes)
{
    return objectBytes >= MinimumObjectBytes;
}

bool LaxoriLargeObjectSpace::IsPowerOfTwo(size_t value)
{
    return (value != 0) && ((value & (value - 1)) == 0);
}

bool LaxoriLargeObjectSpace::TryAdd(uintptr_t left, size_t right, uintptr_t* result)
{
    if ((result == nullptr) || (right > (UINTPTR_MAX - left)))
    {
        return false;
    }

    *result = left + right;
    return true;
}

bool LaxoriLargeObjectSpace::TryAlignUp(size_t value, size_t alignment, size_t* result)
{
    if ((result == nullptr) || !IsPowerOfTwo(alignment) || (value > (SIZE_MAX - (alignment - 1))))
    {
        return false;
    }

    *result = (value + (alignment - 1)) & ~(alignment - 1);
    return true;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::ComputeAllocationGeometry(
    uintptr_t pageStart,
    size_t objectBytes,
    size_t alignment,
    size_t alignmentOffset,
    LaxoriLargeObjectAllocation* allocation)
{
    if ((allocation == nullptr) ||
        (objectBytes == 0) ||
        !IsPowerOfTwo(alignment) ||
    (alignment > PageBytes) ||
    (alignmentOffset >= alignment) ||
        ((pageStart & (PageBytes - 1)) != 0))
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    if (!ShouldUseLargeObjectSpace(objectBytes))
    {
        return LaxoriLargeObjectResult::BelowThreshold;
    }

    uintptr_t adjusted;
    if (!TryAdd(pageStart, alignmentOffset, &adjusted))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }
    size_t misalignment = static_cast<size_t>(adjusted & (alignment - 1));
    size_t padding = misalignment == 0 ? 0 : alignment - misalignment;
    if (objectBytes > (SIZE_MAX - padding))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }

    size_t usedBytes = padding + objectBytes;
    size_t pageBytes;
    if (!TryAlignUp(usedBytes, PageBytes, &pageBytes))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }

    uintptr_t object;
    uintptr_t end;
    if (!TryAdd(pageStart, padding, &object) ||
        !TryAdd(pageStart, pageBytes, &end) ||
        (end > LaxoriSideMetadataLayout::AddressLimit))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }

    allocation->object = object;
    allocation->page_start = pageStart;
    allocation->object_bytes = objectBytes;
    allocation->page_count = pageBytes / PageBytes;
    allocation->padding_bytes = padding;
    allocation->owner = 0;
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::FromMetadataResult(SideMetadataResult result)
{
    return result == SideMetadataResult::Success ?
        LaxoriLargeObjectResult::Success :
        LaxoriLargeObjectResult::MetadataFailure;
}

void LaxoriLargeObjectSpace::EnterLock() const
{
    uint32_t switchCount = 0;
    while (m_lock.test_and_set(std::memory_order_acquire))
    {
        GCToOSInterface::YieldThread(switchCount++);
    }
}

void LaxoriLargeObjectSpace::ExitLock() const
{
    m_lock.clear(std::memory_order_release);
}

LaxoriLargeObjectSpace::LockScope::LockScope(const LaxoriLargeObjectSpace* space)
    : m_space(space)
{
    m_space->EnterLock();
}

LaxoriLargeObjectSpace::LockScope::~LockScope()
{
    m_space->ExitLock();
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::Initialize(
    SideMetadataManager* metadata,
    size_t reservationBytes,
    void* suppliedReservation,
    size_t admittedBytes)
{
    admittedBytes = admittedBytes == 0 ? reservationBytes : admittedBytes;
    if ((metadata == nullptr) ||
        (reservationBytes == 0) ||
        admittedBytes > reservationBytes || admittedBytes % PageBytes != 0 ||
        ((reservationBytes & (PageBytes - 1)) != 0) ||
        ((reinterpret_cast<uintptr_t>(suppliedReservation) & (PageBytes - 1)) != 0))
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    if (sizeof(uintptr_t) != sizeof(uint64_t))
    {
        return LaxoriLargeObjectResult::UnsupportedAddressSpace;
    }
#ifdef LAXORI_SIDE_METADATA_TEST_PLATFORM
    size_t pageSize = GCToOSInterface::GetPageSize();
#else
    size_t pageSize = minipal_getpagesize();
#endif
    if (pageSize != PageBytes)
    {
        return LaxoriLargeObjectResult::UnsupportedPageSize;
    }

    LockScope lock(this);
    if ((m_reservation != nullptr) || (m_phase.load(std::memory_order_acquire) != LaxoriLargeObjectPhase::Shutdown))
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }

    const LaxoriSideMetadataKind required[] =
    {
        LaxoriSideMetadataKind::ValidObject,
        LaxoriSideMetadataKind::ReferenceCount,
        LaxoriSideMetadataKind::FieldUnlogged,
        LaxoriSideMetadataKind::ObjectMark,
        LaxoriSideMetadataKind::LargeObjectMarkNursery,
        LaxoriSideMetadataKind::LargeObjectPageReuse,
    };
    for (LaxoriSideMetadataKind kind : required)
    {
        if (!metadata->IsSpecEnabled(kind))
        {
            return LaxoriLargeObjectResult::MetadataFailure;
        }
    }

    Span* initial = new (std::nothrow) Span{
        0,
        admittedBytes / PageBytes,
        0,
        0,
        0,
        0,
        nullptr,
    };
    if (initial == nullptr)
    {
        return LaxoriLargeObjectResult::OutOfMemory;
    }

    bool ownsReservation = suppliedReservation == nullptr;
    void* reservation = ownsReservation
        ? GCToOSInterface::VirtualReserve(reservationBytes, PageBytes, VirtualReserveFlags::NoReserve)
        : suppliedReservation;
    if (reservation == nullptr)
    {
        delete initial;
        return LaxoriLargeObjectResult::ReservationFailed;
    }

    uintptr_t start = reinterpret_cast<uintptr_t>(reservation);
    uintptr_t end;
    if (!TryAdd(start, reservationBytes, &end) ||
        (end > LaxoriSideMetadataLayout::AddressLimit))
    {
        if (ownsReservation)
        {
            GCToOSInterface::VirtualRelease(reservation, reservationBytes);
        }
        delete initial;
        return LaxoriLargeObjectResult::UnsupportedAddressSpace;
    }

    SideMetadataResult metadataResult = metadata->CommitDataRange(start, admittedBytes);
    if (metadataResult != SideMetadataResult::Success)
    {
        if (ownsReservation)
        {
            GCToOSInterface::VirtualRelease(reservation, reservationBytes);
        }
        delete initial;
        return FromMetadataResult(metadataResult);
    }

    initial->page_start = start;

    m_metadata = metadata;
    m_reservation = reservation;
    m_reservation_bytes = reservationBytes;
    m_admitted_bytes.store(admittedBytes, std::memory_order_release);
    m_owns_reservation = ownsReservation;
    m_free_spans = initial;
    m_active_spans = nullptr;
    m_quarantined_spans = nullptr;
    m_span_bytes.store(0, std::memory_order_release);
    m_mark_state.store(0, std::memory_order_release);
    m_phase.store(LaxoriLargeObjectPhase::Mutator, std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::GrowQuiescent(size_t admittedBytes)
{
    LockScope lock(this);
    size_t previous = m_admitted_bytes.load(std::memory_order_relaxed);
    if (m_metadata == nullptr || admittedBytes <= previous || admittedBytes > m_reservation_bytes ||
        admittedBytes % PageBytes != 0 ||
        !m_metadata->IsDataRangeOwned(GetReservationStart(), admittedBytes))
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    Span* span = new (std::nothrow) Span{
        GetReservationStart() + previous, (admittedBytes - previous) / PageBytes,
        0, 0, 0, 0, nullptr,
    };
    if (span == nullptr)
    {
        return LaxoriLargeObjectResult::OutOfMemory;
    }
    InsertFreeAndCoalesce(span);
    m_admitted_bytes.store(admittedBytes, std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

size_t LaxoriLargeObjectSpace::GetAdmittedBytes() const
{
    return m_admitted_bytes.load(std::memory_order_acquire);
}

size_t LaxoriLargeObjectSpace::GetRequiredGrowthBytes(size_t objectBytes) const
{
    LockScope lock(this);
    uintptr_t frontier = GetReservationStart() + m_admitted_bytes.load(std::memory_order_relaxed);
    LaxoriLargeObjectAllocation geometry;
    if (ComputeAllocationGeometry(0, objectBytes, sizeof(uintptr_t), 0, &geometry) !=
        LaxoriLargeObjectResult::Success)
    {
        return SIZE_MAX;
    }
    size_t required = geometry.page_count * PageBytes;
    for (Span* span = m_free_spans; span != nullptr; span = span->next)
    {
        size_t bytes = span->page_count * PageBytes;
        if (span->page_start + bytes == frontier)
        {
            return required > bytes ? required - bytes : 0;
        }
    }
    return required;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::GetMatureCommittedBytes(size_t* bytes) const
{
    size_t slack;
    return GetMatureStatistics(bytes, &slack);
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::GetMatureStatistics(size_t* bytes, size_t* slackBytes) const
{
    if (bytes == nullptr || slackBytes == nullptr)
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    LockScope lock(this);
    *bytes = 0;
    *slackBytes = 0;
    for (Span* span = m_active_spans; span != nullptr; span = span->next)
    {
        uintptr_t state;
        if (m_metadata->Load(LaxoriSideMetadataKind::LargeObjectMarkNursery,
                span->object, SideMetadataMemoryOrder::Relaxed, &state) != SideMetadataResult::Success)
        {
            return LaxoriLargeObjectResult::MetadataFailure;
        }
        if ((state & NurseryBit) == 0)
        {
            size_t pageBytes = span->page_count * PageBytes;
            *bytes += pageBytes;
            *slackBytes += pageBytes - span->object_bytes;
        }
    }
    return LaxoriLargeObjectResult::Success;
}

void LaxoriLargeObjectSpace::DeleteSpans(Span* span)
{
    while (span != nullptr)
    {
        Span* next = span->next;
        delete span;
        span = next;
    }
}

void LaxoriLargeObjectSpace::Shutdown()
{
    LockScope lock(this);
    if (m_reservation != nullptr && m_owns_reservation)
    {
        GCToOSInterface::VirtualRelease(m_reservation, m_reservation_bytes);
    }
    DeleteSpans(m_free_spans);
    DeleteSpans(m_active_spans);
    DeleteSpans(m_quarantined_spans);
    m_metadata = nullptr;
    m_reservation = nullptr;
    m_reservation_bytes = 0;
    m_owns_reservation = false;
    m_free_spans = nullptr;
    m_active_spans = nullptr;
    m_quarantined_spans = nullptr;
    m_span_bytes.store(0, std::memory_order_release);
    m_mark_state.store(0, std::memory_order_release);
    m_phase.store(LaxoriLargeObjectPhase::Shutdown, std::memory_order_release);
}

LaxoriLargeObjectPhase LaxoriLargeObjectSpace::GetPhase() const
{
    return m_phase.load(std::memory_order_acquire);
}

uint8_t LaxoriLargeObjectSpace::GetMarkState() const
{
    return m_mark_state.load(std::memory_order_acquire);
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::BeginCollection(bool concurrent, bool fullTrace)
{
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) != LaxoriLargeObjectPhase::Mutator)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    if (fullTrace)
    {
        m_mark_state.fetch_xor(MarkBit, std::memory_order_seq_cst);
    }
    m_phase.store(
        concurrent ? LaxoriLargeObjectPhase::ConcurrentMark : LaxoriLargeObjectPhase::Release,
        std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::BeginRelease()
{
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) != LaxoriLargeObjectPhase::ConcurrentMark)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    m_phase.store(LaxoriLargeObjectPhase::Release, std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::EndCollection()
{
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) != LaxoriLargeObjectPhase::Release)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    m_phase.store(LaxoriLargeObjectPhase::Mutator, std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectSpace::Span* LaxoriLargeObjectSpace::FindActive(
    uintptr_t object,
    Span** previous) const
{
    Span* prior = nullptr;
    for (Span* span = m_active_spans; span != nullptr; span = span->next)
    {
        if (span->object == object)
        {
            if (previous != nullptr)
            {
                *previous = prior;
            }
            return span;
        }
        prior = span;
    }
    if (previous != nullptr)
    {
        *previous = nullptr;
    }
    return nullptr;
}

LaxoriLargeObjectSpace::Span* LaxoriLargeObjectSpace::FindFree(
    size_t pageCount,
    Span** previous) const
{
    Span* prior = nullptr;
    for (Span* span = m_free_spans; span != nullptr; span = span->next)
    {
        if (span->page_count >= pageCount)
        {
            if (previous != nullptr)
            {
                *previous = prior;
            }
            return span;
        }
        prior = span;
    }
    if (previous != nullptr)
    {
        *previous = nullptr;
    }
    return nullptr;
}

void LaxoriLargeObjectSpace::RemoveSpan(Span** head, Span* span, Span* previous)
{
    if (previous == nullptr)
    {
        *head = span->next;
    }
    else
    {
        previous->next = span->next;
    }
    span->next = nullptr;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::ResetAllocationMetadata(
    uintptr_t pageStart,
    size_t pageBytes)
{
    const LaxoriSideMetadataKind resetKinds[] =
    {
        LaxoriSideMetadataKind::ValidObject,
        LaxoriSideMetadataKind::ReferenceCount,
        LaxoriSideMetadataKind::FieldUnlogged,
        LaxoriSideMetadataKind::ObjectMark,
        LaxoriSideMetadataKind::LargeObjectMarkNursery,
    };
    for (LaxoriSideMetadataKind kind : resetKinds)
    {
        SideMetadataResult result = m_metadata->ResetRangeQuiescent(
            kind,
            pageStart,
            pageBytes,
            0);
        if (result != SideMetadataResult::Success)
        {
            return FromMetadataResult(result);
        }
    }
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::InitializeAllocationMetadata(
    const LaxoriLargeObjectAllocation& allocation)
{
    size_t pageBytes = allocation.page_count * PageBytes;
    LaxoriLargeObjectResult result = ResetAllocationMetadata(allocation.page_start, pageBytes);
    if (result != LaxoriLargeObjectResult::Success)
    {
        return result;
    }

    if (m_phase.load(std::memory_order_relaxed) == LaxoriLargeObjectPhase::ConcurrentMark)
    {
        for (size_t page = 0; page < allocation.page_count; page++)
        {
            uintptr_t previous;
            SideMetadataResult metadataResult = m_metadata->FetchAddWrapping(
                LaxoriSideMetadataKind::LargeObjectPageReuse,
                allocation.page_start + (page * PageBytes),
                1,
                SideMetadataMemoryOrder::SequentiallyConsistent,
                &previous);
            if (metadataResult != SideMetadataResult::Success)
            {
                return FromMetadataResult(metadataResult);
            }
        }
    }

    uint8_t state = static_cast<uint8_t>(
        m_mark_state.load(std::memory_order_relaxed) | NurseryBit);
    SideMetadataResult metadataResult = m_metadata->Store(
        LaxoriSideMetadataKind::LargeObjectMarkNursery,
        allocation.object,
        state,
        SideMetadataMemoryOrder::SequentiallyConsistent);
    if (metadataResult == SideMetadataResult::Success)
    {
        metadataResult = m_metadata->Store(
            LaxoriSideMetadataKind::ValidObject,
            allocation.object,
            1,
            SideMetadataMemoryOrder::SequentiallyConsistent);
    }
    return FromMetadataResult(metadataResult);
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::Allocate(
    size_t objectBytes,
    size_t alignment,
    size_t alignmentOffset,
    uintptr_t owner,
    LaxoriLargeObjectAllocation* allocation)
{
    if ((allocation == nullptr) || (owner == 0))
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }

    LockScope lock(this);
    LaxoriLargeObjectPhase phase = m_phase.load(std::memory_order_relaxed);
    if (phase == LaxoriLargeObjectPhase::Shutdown)
    {
        return LaxoriLargeObjectResult::NotInitialized;
    }
    if ((phase != LaxoriLargeObjectPhase::Mutator) &&
        (phase != LaxoriLargeObjectPhase::ConcurrentMark))
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }

    LaxoriLargeObjectAllocation maximum;
    LaxoriLargeObjectResult result = ComputeAllocationGeometry(
        0,
        objectBytes,
        alignment,
        alignmentOffset,
        &maximum);
    if (result != LaxoriLargeObjectResult::Success)
    {
        return result;
    }

    Span* freePrevious;
    Span* freeSpan = FindFree(maximum.page_count, &freePrevious);
    if (freeSpan == nullptr)
    {
        return LaxoriLargeObjectResult::OutOfMemory;
    }

    LaxoriLargeObjectAllocation candidate;
    result = ComputeAllocationGeometry(
        freeSpan->page_start,
        objectBytes,
        alignment,
        alignmentOffset,
        &candidate);
    if (result != LaxoriLargeObjectResult::Success)
    {
        return result;
    }
    candidate.owner = owner;

    Span* active = new (std::nothrow) Span{
        candidate.page_start,
        candidate.page_count,
        candidate.object,
        candidate.object_bytes,
        candidate.padding_bytes,
        owner,
        nullptr,
    };
    if (active == nullptr)
    {
        return LaxoriLargeObjectResult::OutOfMemory;
    }

    size_t committedBytes = candidate.page_count * PageBytes;
    if (!GCToOSInterface::VirtualCommit(
            reinterpret_cast<void*>(candidate.page_start),
            committedBytes))
    {
        delete active;
        return LaxoriLargeObjectResult::CommitFailed;
    }
    memset(reinterpret_cast<void*>(candidate.page_start), 0, committedBytes);

    result = InitializeAllocationMetadata(candidate);
    if (result != LaxoriLargeObjectResult::Success)
    {
        GCToOSInterface::VirtualDecommit(
            reinterpret_cast<void*>(candidate.page_start),
            committedBytes);
        delete active;
        return result;
    }

    if (freeSpan->page_count == candidate.page_count)
    {
        RemoveSpan(&m_free_spans, freeSpan, freePrevious);
        delete freeSpan;
    }
    else
    {
        freeSpan->page_start += committedBytes;
        freeSpan->page_count -= candidate.page_count;
    }

    active->next = m_active_spans;
    m_active_spans = active;
    m_span_bytes.fetch_add(committedBytes, std::memory_order_release);
    *allocation = candidate;
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::TryMarkAndPromote(
    uintptr_t object,
    uintptr_t owner,
    bool* updated,
    bool unlogFields)
{
    if (updated == nullptr)
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    *updated = false;

    LockScope lock(this);
    LaxoriLargeObjectPhase phase = m_phase.load(std::memory_order_relaxed);
    if (phase != LaxoriLargeObjectPhase::Release)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }

    Span* span = FindActive(object, nullptr);
    if (span == nullptr)
    {
        return LaxoriLargeObjectResult::NotFound;
    }
    if (span->owner != owner)
    {
        return LaxoriLargeObjectResult::NotOwner;
    }

    size_t fieldMetadataBytes;
    if (!TryAlignUp(
            span->object_bytes,
            FieldMetadataGranularity,
            &fieldMetadataBytes))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }

    size_t committedBytes = span->page_count * PageBytes;
    size_t objectOffset = span->object - span->page_start;
    if ((objectOffset > committedBytes) ||
        (fieldMetadataBytes > (committedBytes - objectOffset)))
    {
        return LaxoriLargeObjectResult::AddressOverflow;
    }

    if (unlogFields)
    {
        SideMetadataResult metadataResult = m_metadata->ResetRangeQuiescent(
            LaxoriSideMetadataKind::FieldUnlogged,
            span->object,
            fieldMetadataBytes,
            1);
        if (metadataResult != SideMetadataResult::Success)
        {
            return FromMetadataResult(metadataResult);
        }
    }

    uintptr_t oldState;
    SideMetadataResult metadataResult = m_metadata->Load(
        LaxoriSideMetadataKind::LargeObjectMarkNursery,
        object,
        SideMetadataMemoryOrder::SequentiallyConsistent,
        &oldState);
    if (metadataResult != SideMetadataResult::Success)
    {
        return FromMetadataResult(metadataResult);
    }
    uintptr_t desired = m_mark_state.load(std::memory_order_relaxed);
    if (oldState == desired)
    {
        return LaxoriLargeObjectResult::Success;
    }

    uintptr_t observed;
    bool exchanged;
    metadataResult = m_metadata->CompareExchange(
        LaxoriSideMetadataKind::LargeObjectMarkNursery,
        object,
        desired,
        oldState,
        SideMetadataMemoryOrder::SequentiallyConsistent,
        &observed,
        &exchanged);
    *updated = exchanged;
    return FromMetadataResult(metadataResult);
}

void LaxoriLargeObjectSpace::InsertFreeAndCoalesce(Span* span)
{
    span->object = 0;
    span->object_bytes = 0;
    span->padding_bytes = 0;
    span->owner = 0;

    Span* previous = nullptr;
    Span* current = m_free_spans;
    while ((current != nullptr) && (current->page_start < span->page_start))
    {
        previous = current;
        current = current->next;
    }
    span->next = current;
    if (previous == nullptr)
    {
        m_free_spans = span;
    }
    else
    {
        previous->next = span;
    }

    if ((previous != nullptr) &&
        (previous->page_start + (previous->page_count * PageBytes) == span->page_start))
    {
        previous->page_count += span->page_count;
        previous->next = span->next;
        delete span;
        span = previous;
    }
    if ((span->next != nullptr) &&
        (span->page_start + (span->page_count * PageBytes) == span->next->page_start))
    {
        Span* next = span->next;
        span->page_count += next->page_count;
        span->next = next->next;
        delete next;
    }
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::TryRelease(
    uintptr_t object,
    uintptr_t owner)
{
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) != LaxoriLargeObjectPhase::Release)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }

    return ReleaseLocked(object, owner);
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::ReleaseLocked(uintptr_t object, uintptr_t owner)
{
    Span* previous;
    Span* span = FindActive(object, &previous);
    if (span == nullptr)
    {
        return LaxoriLargeObjectResult::NotFound;
    }
    if (span->owner != owner)
    {
        return LaxoriLargeObjectResult::NotOwner;
    }

    size_t pageBytes = span->page_count * PageBytes;
    if (!GCToOSInterface::VirtualDecommit(
            reinterpret_cast<void*>(span->page_start),
            pageBytes))
    {
        return LaxoriLargeObjectResult::DecommitFailed;
    }

    LaxoriLargeObjectResult result = ResetAllocationMetadata(span->page_start, pageBytes);
    RemoveSpan(&m_active_spans, span, previous);
    if (result != LaxoriLargeObjectResult::Success)
    {
        span->next = m_quarantined_spans;
        m_quarantined_spans = span;
        return result;
    }

    InsertFreeAndCoalesce(span);
    m_span_bytes.fetch_sub(pageBytes, std::memory_order_release);
    return LaxoriLargeObjectResult::Success;
}

#ifdef LAXORI_ENABLE_LAZY_COMPLETION_COUNTER
LaxoriLargeObjectResult LaxoriLargeObjectSpace::ReleaseAfterDecrements(
    uintptr_t object, uintptr_t owner, const LaxoriBlockReleaseGuard& guard)
{
    if (!guard.IsValid())
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    LockScope lock(this);
    LaxoriLargeObjectPhase phase = m_phase.load(std::memory_order_relaxed);
    // The lazy release runs after the pause that killed the object. While a concurrent trace is active the space
    // is in ConcurrentMark between pauses, so that phase must be accepted too. The dying object was marked and
    // scanned before its count reached zero (FinishDyingTraceObject), so the trace holds no reference to it.
    if (phase == LaxoriLargeObjectPhase::Shutdown)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    uintptr_t count = 0;
    uintptr_t state = 0;
    SideMetadataResult result = m_metadata->Load(
        LaxoriSideMetadataKind::ReferenceCount, object,
        SideMetadataMemoryOrder::SequentiallyConsistent, &count);
    if (result != SideMetadataResult::Success)
    {
        return FromMetadataResult(result);
    }
    result = m_metadata->Load(
        LaxoriSideMetadataKind::LargeObjectMarkNursery, object,
        SideMetadataMemoryOrder::SequentiallyConsistent, &state);
    if (result != SideMetadataResult::Success)
    {
        return FromMetadataResult(result);
    }
    if (count != 0 || (state & NurseryBit) != 0)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    return ReleaseLocked(object, owner);
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::SweepNursery(size_t* releasedBytes)
{
    if (releasedBytes == nullptr)
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    *releasedBytes = 0;
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) != LaxoriLargeObjectPhase::Release)
    {
        return LaxoriLargeObjectResult::InvalidPhase;
    }
    Span* span = m_active_spans;
    while (span != nullptr)
    {
        Span* next = span->next;
        uintptr_t state = 0;
        uintptr_t count = 0;
        SideMetadataResult result = m_metadata->Load(
            LaxoriSideMetadataKind::LargeObjectMarkNursery, span->object,
            SideMetadataMemoryOrder::SequentiallyConsistent, &state);
        if (result == SideMetadataResult::Success)
        {
            result = m_metadata->Load(
                LaxoriSideMetadataKind::ReferenceCount, span->object,
                SideMetadataMemoryOrder::SequentiallyConsistent, &count);
        }
        if (result != SideMetadataResult::Success)
        {
            return FromMetadataResult(result);
        }
        if ((state & NurseryBit) != 0 && count == 0)
        {
            size_t bytes = span->page_count * PageBytes;
            LaxoriLargeObjectResult released = ReleaseLocked(span->object, span->owner);
            if (released != LaxoriLargeObjectResult::Success)
            {
                return released;
            }
            *releasedBytes += bytes;
        }
        span = next;
    }
    return LaxoriLargeObjectResult::Success;
}
#endif

uintptr_t LaxoriLargeObjectSpace::GetReservationStart() const
{
    return reinterpret_cast<uintptr_t>(m_reservation);
}

size_t LaxoriLargeObjectSpace::GetReservationBytes() const
{
    return m_reservation_bytes;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::GetAllocation(
    uintptr_t object,
    LaxoriLargeObjectAllocation* allocation) const
{
    if (allocation == nullptr)
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }

    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) == LaxoriLargeObjectPhase::Shutdown)
    {
        return LaxoriLargeObjectResult::NotInitialized;
    }
    Span* span = FindActive(object, nullptr);
    if (span == nullptr)
    {
        return LaxoriLargeObjectResult::NotFound;
    }
    allocation->object = span->object;
    allocation->page_start = span->page_start;
    allocation->object_bytes = span->object_bytes;
    allocation->page_count = span->page_count;
    allocation->padding_bytes = span->padding_bytes;
    allocation->owner = span->owner;
    return LaxoriLargeObjectResult::Success;
}

LaxoriLargeObjectResult LaxoriLargeObjectSpace::GetContainingAllocation(
    uintptr_t address,
    LaxoriLargeObjectAllocation* allocation) const
{
    if (allocation == nullptr)
    {
        return LaxoriLargeObjectResult::InvalidArgument;
    }
    LockScope lock(this);
    if (m_phase.load(std::memory_order_relaxed) == LaxoriLargeObjectPhase::Shutdown)
    {
        return LaxoriLargeObjectResult::NotInitialized;
    }
    for (Span* span = m_active_spans; span != nullptr; span = span->next)
    {
        if (address >= span->object && address - span->object < span->object_bytes)
        {
            *allocation = {span->object, span->page_start, span->object_bytes,
                span->page_count, span->padding_bytes, span->owner};
            return LaxoriLargeObjectResult::Success;
        }
    }
    return LaxoriLargeObjectResult::NotFound;
}
