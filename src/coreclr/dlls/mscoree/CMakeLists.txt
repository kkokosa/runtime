include_directories("../../inc")

if(FEATURE_GDBJIT)
   add_definitions(-DFEATURE_GDBJIT)
endif(FEATURE_GDBJIT)

set(CLR_SOURCES
    mscoree.cpp
    exports.cpp
)

if(CLR_CMAKE_TARGET_WIN32)
list(APPEND CLR_SOURCES
  Native.rc
)
set (DEF_SOURCES
  mscorwks_ntdef.src
)
else()
if(CLR_CMAKE_ENABLE_WRITE_BARRIER_STANDARD_ABI_TEST AND CLR_CMAKE_ENABLE_ALLOCATION_NOTIFICATION_TEST)
  set (DEF_SOURCES
    mscorwks_validation_unixexports.src
  )
elseif(CLR_CMAKE_ENABLE_WRITE_BARRIER_STANDARD_ABI_TEST)
  set (DEF_SOURCES
    mscorwks_writebarriertest_unixexports.src
  )
elseif(CLR_CMAKE_ENABLE_ALLOCATION_NOTIFICATION_TEST)
  set (DEF_SOURCES
    mscorwks_allocationnotificationtest_unixexports.src
  )
else()
  set (DEF_SOURCES
    mscorwks_unixexports.src
  )
endif()
if(CLR_CMAKE_ENABLE_OBJECT_HEADER_BITS_TEST)
  list(APPEND DEF_SOURCES
    mscorwks_objectheaderbitstest_unixexports.src
  )
endif()
if(CLR_CMAKE_ENABLE_IMMIX_BLOCK_STATE_TEST)
  list(APPEND DEF_SOURCES
    mscorwks_immixblockstatetest_unixexports.src
  )
endif()
if(FEATURE_GDBJIT)
  list(APPEND DEF_SOURCES
    gdbjit_unixexports.src
  )
endif(FEATURE_GDBJIT)
endif(CLR_CMAKE_TARGET_WIN32)

convert_to_absolute_path(DEF_SOURCES ${DEF_SOURCES})
convert_to_absolute_path(CLR_SOURCES ${CLR_SOURCES})
add_subdirectory(coreclr)
