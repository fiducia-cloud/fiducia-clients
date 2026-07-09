cmake_minimum_required(VERSION 3.15)

project(fiducia_client
  VERSION 0.1.0
  DESCRIPTION "Fiducia HTTP client (C, libcurl)"
  HOMEPAGE_URL "https://github.com/fiducia-cloud/fiducia-clients"
  LANGUAGES C)

# libcurl is the only dependency (HTTP transport). C has no stdlib JSON, so the
# client does not parse responses -- callers bring their own JSON parser.
find_package(CURL REQUIRED)

add_library(fiducia STATIC fiducia.c)
add_library(fiducia::fiducia ALIAS fiducia)

target_sources(fiducia
  PUBLIC
    FILE_SET HEADERS
    BASE_DIRS ${CMAKE_CURRENT_SOURCE_DIR}
    FILES fiducia.h)

target_include_directories(fiducia
  PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:include>)

target_link_libraries(fiducia PUBLIC CURL::libcurl)

target_compile_features(fiducia PUBLIC c_std_11)
set_target_properties(fiducia PROPERTIES
  C_STANDARD 11
  C_STANDARD_REQUIRED ON
  C_EXTENSIONS OFF)

include(GNUInstallDirs)
install(TARGETS fiducia
  EXPORT fiduciaTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  FILE_SET HEADERS DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
