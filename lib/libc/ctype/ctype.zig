// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C character classification.
//
// The Zig counterpart of NetBSD's lib/libc/gen/ctype_*.c (the C locale only).
// Each returns non-zero when the character is in the class.

pub fn isdigit(c: c_int) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

pub fn isspace(c: c_int) c_int {
    return @intFromBool(c == ' ' or (c >= 0x09 and c <= 0x0d));
}

pub fn isalpha(c: c_int) c_int {
    return @intFromBool((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'));
}

pub fn isalnum(c: c_int) c_int {
    return @intFromBool(isalpha(c) != 0 or isdigit(c) != 0);
}

pub fn isupper(c: c_int) c_int {
    return @intFromBool(c >= 'A' and c <= 'Z');
}

pub fn islower(c: c_int) c_int {
    return @intFromBool(c >= 'a' and c <= 'z');
}

pub fn isxdigit(c: c_int) c_int {
    return @intFromBool(isdigit(c) != 0 or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'));
}

pub fn isprint(c: c_int) c_int {
    return @intFromBool(c >= 0x20 and c < 0x7f);
}

pub fn toupper(c: c_int) c_int {
    if (islower(c) != 0) {
        return c - 32;
    }
    return c;
}

pub fn tolower(c: c_int) c_int {
    if (isupper(c) != 0) {
        return c + 32;
    }
    return c;
}
