// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The firmware- and machine-independent loader.
//
// The counterpart of FreeBSD's stand/common and stand/lua: everything the
// loader does that does not depend on the firmware or the CPU.
//
//   env.zig        the loader environment and loader.conf
//   menu.zig       the boot menu, with its autoboot countdown
//   interp.zig     the OK prompt and its commands
//   gfx_renux.zig  the brand and the logo the menu draws
//   gfx_fb.zig     a text console drawn on a linear framebuffer (used by the
//                  firmware side, which owns the framebuffer)
//
// The firmware side (bootloader/efi) provides the console, the keyboard and
// the files as the "platform" module and drives these; see the list of what
// it must provide at the top of bootloader/efi/efi_cons.zig.

pub const env: type = @import("env.zig");
pub const menu: type = @import("menu.zig");
pub const interp: type = @import("interp.zig");
pub const gfx: type = @import("gfx_renux.zig");
