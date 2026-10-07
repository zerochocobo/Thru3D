cmake_minimum_required(VERSION 3.22)
project(QuestNcnnToolchainSmoke LANGUAGES CXX)
find_package(ncnn CONFIG REQUIRED)
add_library(quest_ncnn_smoke SHARED smoke.cpp)
target_compile_features(quest_ncnn_smoke PRIVATE cxx_std_17)
target_link_libraries(quest_ncnn_smoke PRIVATE ncnn log android)
target_link_options(quest_ncnn_smoke PRIVATE "-Wl,-z,max-page-size=16384")

