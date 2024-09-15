#!/usr/bin/env bash

set -ex

clang-format --dry-run gui/*.h gui/*.cpp -Werror
zig fmt --check src
#zig build
