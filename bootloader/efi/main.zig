// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// The Renux UEFI boot loader.
//
// The counterpart of FreeBSD's stand/efi/loader/main.c. The firmware starts
// it as \EFI\BOOT\BOOTX64.EFI; it then:
//
//   1. takes over the console (efi_cons.zig), reports itself and the
//      firmware, and reads /boot/defaults/loader.conf, /boot/loader.conf and
//      /boot/loader.conf.local into the loader environment;
//   2. shows the boot menu (bootloader/common/menu.zig) with its autoboot
//      countdown, or the OK prompt (bootloader/common/interp.zig);
//   3. loads the chosen kernel's ELF image (load_elf.zig);
//   4. hands the machine to it (handoff.zig): the BootInfo, the kernel's page
//      tables, ExitBootServices and the jump.
//
// When a boot fails, the reason is printed and the loader drops to the OK
// prompt, as FreeBSD's does. Everything printed describes what the loader
// actually did.
//
// Source layout of the loader:
//
//   bootloader/common/             firmware- and machine-independent: the
//                                  environment, the menu, the prompt
//   bootloader/efi/                UEFI, machine-independent: this file, the
//                                  console and files, ELF loading, hand-off
//   bootloader/arch/amd64/efi/     UEFI on amd64: page tables, kernel entry
//   bootloader/arch/amd64/protocol the Renux boot protocol (shared with the
//                                  kernel)

const std: type = @import("std");
const uefi: type = std.os.uefi;
const libefi: type = @import("libefi");
const platform: type = @import("platform");
const common: type = @import("common");
const env: type = common.env;
const menu: type = common.menu;
const interp: type = common.interp;
const load_elf: type = @import("load_elf.zig");
const handoff: type = @import("handoff.zig");

/// Loader version, printed in the banner.
const REVISION: []const u8 = "0.1";

/// The settings used when /boot/defaults/loader.conf is missing, so the
/// loader still boots without it.
const BUILTIN_DEFAULTS: []const [2][]const u8 = &.{
    .{ "autoboot_delay", "10" },
    .{ "kernel", "kernel" },
    .{ "kernels", "kernel kernel.old" },
};

/// The loader configuration files, read in this order; later ones override
/// earlier ones.
const DEFAULTS_CONF: []const u8 = "/boot/defaults/loader.conf";
const LOCAL_CONFS: []const []const u8 = &.{ "/boot/loader.conf", "/boot/loader.conf.local" };

pub fn main() uefi.Error!void {
    // The firmware's watchdog would reset the machine while the menu waits.
    libefi.bootServices().setWatchdogTimer(0, 0, null) catch {};
    platform.consInit();

    if (!platform.openBootVolume()) {
        platform.print("loader: cannot open the boot volume\n");
        return error.NotFound;
    }
    banner();
    loadConfiguration();

    // FreeBSD's flow: the menu, unless beastie_disable is set; then an
    // autoboot countdown at the prompt instead. A failed boot lands on the
    // prompt.
    var use_menu: bool = !env.isYes("beastie_disable");
    var at_prompt: bool = false;
    if (!use_menu) {
        at_prompt = !interp.autoboot(env.getNumber("autoboot_delay", 10));
    }
    while (true) {
        if (use_menu and !at_prompt) {
            const choice: menu.Action = menu.run();
            menu.finish();
            if (choice == .prompt) at_prompt = true;
        }
        if (at_prompt) {
            if (interp.run() == .menu) {
                at_prompt = false;
                use_menu = true;
                continue;
            }
        }
        bootKernel() catch {};
        // The reason was printed; fall back to the prompt.
        at_prompt = true;
    }
}

/// Fill the loader environment from the configuration files.
fn loadConfiguration() void {
    if (!env.loadConf(DEFAULTS_CONF)) {
        for (BUILTIN_DEFAULTS) |setting| _ = env.set(setting[0], setting[1]);
    }
    for (LOCAL_CONFS) |path| _ = env.loadConf(path);
}

/// Load the kernel the environment names and start it. Returns only when
/// that fails (the reason has been printed).
fn bootKernel() !void {
    var path_buf: [128]u8 = undefined;
    const name: []const u8 = env.get("kernel") orelse "kernel";
    const path: []const u8 = menu.kernelPath(&path_buf, name) orelse return error.NameTooLong;

    const kernel: load_elf.Kernel = try load_elf.load(path, name);
    try handoff.start(kernel);
}

// -- banner ------------------------------------------------------------------

/// Print the loader's banner and what the firmware reports about itself, as
/// FreeBSD's loader does:
///
///     Consoles: EFI console
///     Renux/amd64 EFI loader, Revision 0.1
///
///        Image base: 0x...
///        EFI version: 2.70
///        EFI Firmware: EDK II (rev 1.00)
///        Load Path: \EFI\BOOT\BOOTX64.EFI
fn banner() void {
    platform.print("Consoles: EFI console\n");
    platform.printf("Renux/amd64 EFI loader, Revision {s}\n\n", .{REVISION});
    const image: *const uefi.protocol.LoadedImage = (libefi.bootServices().handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    platform.printf("   Image base: 0x{x}\n", .{@intFromPtr(image.image_base)});
    platform.print("   EFI version: ");
    platform.printEfiVersion();
    platform.print("\n   EFI Firmware: ");
    platform.printFirmware();
    platform.print("\n   Load Path: ");
    printLoadPath(image);
    platform.print("\n\n");
}

/// UEFI device path node: type and subtype of a file path, and of the node
/// that ends a path (UEFI spec, "Device Path Protocol").
const DEVICE_PATH_MEDIA: u8 = 0x04;
const DEVICE_PATH_MEDIA_FILE_PATH: u8 = 0x04;
const DEVICE_PATH_END: u8 = 0x7f;
/// Every node starts with type (1 byte), subtype (1) and length (2).
const DEVICE_PATH_HEADER_SIZE: u16 = 4;
/// A guard against a malformed path that never ends.
const DEVICE_PATH_MAX_NODES: usize = 32;

/// Print the path the firmware loaded the loader from: the file path nodes
/// of the loaded image's device path.
fn printLoadPath(image: *const uefi.protocol.LoadedImage) void {
    var node: [*]const u8 = @ptrCast(image.file_path);
    for (0..DEVICE_PATH_MAX_NODES) |_| {
        const node_type: u8 = node[0];
        const node_subtype: u8 = node[1];
        const node_len: u16 = std.mem.readInt(u16, node[2..4], .little);
        if (node_type == DEVICE_PATH_END or node_len < DEVICE_PATH_HEADER_SIZE) break;
        if (node_type == DEVICE_PATH_MEDIA and node_subtype == DEVICE_PATH_MEDIA_FILE_PATH) {
            // The node's payload is a UCS-2 path, possibly unaligned.
            var ucs2: [128]u16 = undefined;
            const chars: usize = @min((node_len - DEVICE_PATH_HEADER_SIZE) / 2, ucs2.len);
            for (0..chars) |i| ucs2[i] = std.mem.readInt(u16, node[DEVICE_PATH_HEADER_SIZE + 2 * i ..][0..2], .little);
            var ascii: [128]u8 = undefined;
            platform.print(libefi.ucs2ToAscii(ucs2[0..chars], &ascii));
        }
        node += node_len;
    }
}
