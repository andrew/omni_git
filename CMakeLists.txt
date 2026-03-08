cmake_minimum_required(VERSION 3.25.1)
project(omni_git)

include(CTest)

list(PREPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_LIST_DIR}/../../cmake)

enable_testing()
find_package(PostgreSQL REQUIRED)
find_package(PkgConfig REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(ZLIB REQUIRED)
pkg_check_modules(LIBGIT2 REQUIRED libgit2)

add_postgresql_extension(
        omni_git
        COMMENT "Git object storage and smart HTTP transport"
        SCHEMA omni_git
        RELOCATABLE false
        REQUIRES pgcrypto
        SOURCES omni_git.c)

target_include_directories(omni_git PRIVATE ${LIBGIT2_INCLUDE_DIRS})
target_link_libraries(omni_git ${LIBGIT2_LIBRARIES} OpenSSL::Crypto ZLIB::ZLIB)
target_link_directories(omni_git PRIVATE ${LIBGIT2_LIBRARY_DIRS})
