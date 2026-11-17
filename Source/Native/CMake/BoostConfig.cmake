if(NOT TARGET Boost::boost)
    add_library(Boost::boost INTERFACE IMPORTED)
    set_target_properties(Boost::boost PROPERTIES
        INTERFACE_INCLUDE_DIRECTORIES "${MYOUOU_BOOST_ROOT}"
        INTERFACE_COMPILE_DEFINITIONS "BOOST_ALL_NO_LIB")
endif()

if(NOT TARGET Boost::headers)
    add_library(Boost::headers ALIAS Boost::boost)
endif()

set(Boost_FOUND TRUE)
set(Boost_INCLUDE_DIRS "${MYOUOU_BOOST_ROOT}")
set(Boost_VERSION ${MYOUOU_BOOST_VERSION})
