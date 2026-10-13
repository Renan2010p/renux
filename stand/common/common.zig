// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The machine-independent loader (FreeBSD's stand/common): the environment and
// loader.conf, the boot menu with its brand and logo, and the OK prompt. A
// platform (stand/efi/loader) provides the console, input and files as the
// "platform" module and drives these.

pub const env: type = @import("env.zig");
pub const menu: type = @import("menu.zig");
pub const interp: type = @import("interp.zig");
pub const gfx: type = @import("gfx_renux.zig");
