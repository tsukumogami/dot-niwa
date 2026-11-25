#!/bin/sh
[ -x "$HOME/.tsuku/tools/current/shirabe" ] || exit 0; "$HOME/.tsuku/tools/current/shirabe" compaction pre-compact; exit 0
