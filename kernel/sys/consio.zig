// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Console ioctls.
//
// The Zig counterpart of the display-mode part of FreeBSD's sys/sys/kbio.h
// and sys/sys/consio.h. A graphical program (Xorg, or anything drawing on
// /dev/fb0) puts its terminal in KD_GRAPHICS mode so the text console stops
// drawing over it, and back in KD_TEXT mode when it is done; the console then
// repaints its text.

const ioccom: type = @import("ioccom.zig");

pub const KD_TEXT: i32 = 0; // text mode: the console draws
pub const KD_GRAPHICS: i32 = 1; // graphics mode: the console keeps out

/// Get the display mode (an int).
pub const KDGETMODE: u64 = ioccom.ior('K', 9, c_int);
/// Set the display mode (an int passed by value).
pub const KDSETMODE: u64 = ioccom.iowint('K', 10);
