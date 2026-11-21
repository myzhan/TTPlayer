#!/bin/sh
# Windows 可直接调用 selftest.py；这是 Unix 入口。
exec python3 "$(dirname "$0")/selftest.py" "$@"
