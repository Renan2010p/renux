// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// getopt.
//
// The Zig counterpart of NetBSD's lib/libc/stdlib/getopt.c, reduced to the
// common case: clustered short options, an option argument either attached or
// as the next word, and "--" to stop.

pub export var optind: c_int = 1;
pub export var optarg: ?[*:0]u8 = null;
pub export var optopt: c_int = 0;
pub export var opterr: c_int = 1;

/// Position within the current argument (or a pointer to NUL when between
/// arguments).
var place: [*]const u8 = "";
var started: bool = false;

pub export fn getopt(argc: c_int, argv: [*]?[*:0]u8, optstring: [*:0]const u8) c_int {
    if (!started or place[0] == 0) {
        started = true;
        if (optind >= argc) {
            return -1;
        }
        const arg: [*:0]const u8 = argv[@intCast(optind)] orelse return -1;
        if (arg[0] != '-' or arg[1] == 0) {
            return -1;
        }
        if (arg[1] == '-' and arg[2] == 0) {
            optind += 1;
            return -1;
        }
        place = arg + 1;
    }

    const ch: u8 = place[0];
    place += 1;

    var i: usize = 0;
    while (optstring[i] != 0 and optstring[i] != ch) : (i += 1) {}
    if (optstring[i] == 0) {
        optopt = ch;
        if (place[0] == 0) {
            optind += 1;
        }
        return '?';
    }

    if (optstring[i + 1] != ':') {
        if (place[0] == 0) {
            optind += 1;
        }
        return ch;
    }

    if (place[0] != 0) {
        optarg = @constCast(@as([*:0]const u8, @ptrCast(place)));
        optind += 1;
    } else {
        optind += 1;
        if (optind >= argc) {
            optopt = ch;
            return '?';
        }
        optarg = argv[@intCast(optind)];
        optind += 1;
    }
    place = "";
    return ch;
}
