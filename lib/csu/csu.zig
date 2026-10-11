// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// C startup library root module.
//
// The Zig counterpart of NetBSD/FreeBSD lib/csu: the piece that provides the
// program entry point (_start) and hands control to main(). Userland programs
// import it by name ("csu") alongside the C library.

pub const crt0: type = @import("crt0.zig");
