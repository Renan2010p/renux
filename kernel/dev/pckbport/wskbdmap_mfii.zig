// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// MF-II (US) keyboard map for PS/2 scan code set 1.
//
// The Zig counterpart of NetBSD's sys/dev/pckbport/wskbdmap_mfii.c, reduced to
// the printable ASCII keys. Each table is indexed by a make scan code (0x00 to
// 0x7f); release codes have the high bit set and are handled by the driver.

/// Unshifted map.
pub const normal: [128]u8 = .{
    0,   0x1b, '1', '2', '3', '4', '5', '6', '7',  '8', '9', '0',  '-', '=', 8,   9,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o',  'p', '[', ']',  13,  0,   'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,    ' ', 0,   0,    0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   '7', '8',  '9', '-', '4',  '5', '6', '+', '1',
    '2', '3', '0', '.', 0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,    0,   0,   0,    0,   0,   0,   0,
};

/// Shifted map.
pub const shifted: [128]u8 = .{
    0,   0x1b, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8,   9,
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 13,  0,   'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0,   '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   '7', '8', '9', '-', '4', '5', '6', '+', '1',
    '2', '3', '0', '.', 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
};
