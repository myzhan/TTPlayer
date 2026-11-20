#!/bin/sh
# Windows can invoke selftest.py directly.
exec python3 "$(dirname "$0")/selftest.py" "$@"
