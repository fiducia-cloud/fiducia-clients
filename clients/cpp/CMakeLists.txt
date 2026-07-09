cmake_minimum_required(VERSION 3.14)

project(fiducia_client LANGUAGES CXX VERSION 0.1.0)

# Header-only client, exposed as the INTERFACE target `fiducia::client`.
add_library(fiducia_client INTERFACE)
add_library(fiducia::client ALIAS fiducia_client)

target_compile_features(fiducia_client INTERFACE cxx_std_17)

target_include_directories(fiducia_client INTERFACE
  "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>"
  "$<INSTALL_INTERFACE:include>")

# Runtime dependencies: libcurl (HTTP) + nlohmann/json (JSON).
find_package(CURL REQUIRED)
find_package(nlohmann_json REQUIRED)

target_link_libraries(fiducia_client INTERFACE
  CURL::libcurl
  nlohmann_json::nlohmann_json)
