// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Shutting the system down.
//
// The Zig counterpart of FreeBSD's sys/kern/kern_shutdown.c: reboot(2)
// writes every dirty buffer, unmounts the filesystems so their disks are
// marked clean, reports the uptime and then reboots, halts or powers the
// machine off through the port (arch.cpu_machdep). reboot(8), halt(8) and
// poweroff(8) end here, after they have stopped the other processes.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const arch: type = @import("../arch/arch.zig");
const prf: type = @import("subr_prf.zig");
const kern_proc: type = @import("kern_proc.zig");
const vfs_bio: type = @import("vfs_bio.zig");
const vfs_mount: type = @import("vfs_mount.zig");

/// reboot(2) flags (sys/reboot.h).
pub const RB_AUTOBOOT: u64 = 0x0000;
pub const RB_HALT: u64 = 0x0008;
pub const RB_NOSYNC: u64 = 0x0004;
pub const RB_POWEROFF: u64 = 0x4000;
pub const RB_POWERCYCLE: u64 = 0x400000;

/// "Uptime: 1h2m3s", as FreeBSD prints it (leading zero units left out).
fn printUptime() void {
    var s: u64 = arch.clock.tickCount() / arch.clock.HZ;
    const d: u64 = s / 86400;
    s %= 86400;
    const h: u64 = s / 3600;
    s %= 3600;
    const m: u64 = s / 60;
    s %= 60;
    prf.print("Uptime: ");
    var started: bool = false;
    if (d > 0) {
        prf.printf("%ud", .{d});
        started = true;
    }
    if (started or h > 0) {
        prf.printf("%uh", .{h});
        started = true;
    }
    if (started or m > 0) prf.printf("%um", .{m});
    prf.printf("%us\n", .{s});
}

/// Bring the system down as `howto` says (FreeBSD's kern_reboot()).
pub fn kern_reboot(howto: u64) noreturn {
    if ((howto & RB_NOSYNC) == 0) {
        prf.printf("Syncing disks, buffers remaining... %u ", .{vfs_bio.dirtyCount()});
        vfs_mount.syncAll();
        prf.printf("%u done\n", .{vfs_bio.dirtyCount()});
        // Unmounting marks the disks clean (and syncs them once more).
        vfs_mount.unmountAll();
        if (vfs_bio.dirtyCount() == 0) {
            prf.printLine("All buffers synced.");
        } else {
            prf.printf("Giving up on %u buffers\n", .{vfs_bio.dirtyCount()});
        }
    }
    printUptime();

    if ((howto & RB_HALT) != 0) {
        prf.printLine("");
        prf.printLine("The operating system has halted.");
        prf.printLine("Please press any key to reboot.");
        prf.printLine("");
        arch.cpu_machdep.cpu_halt();
    }
    if ((howto & RB_POWEROFF) != 0) {
        prf.printLine("Powering off...");
        arch.cpu_machdep.cpu_poweroff();
        prf.printLine("Power off is not supported on this machine; halting.");
        arch.cpu_machdep.cpu_halt();
    }
    prf.printLine("Rebooting...");
    arch.cpu_machdep.cpu_reset();
}

/// reboot(2): `reboot(howto)`, for the superuser.
pub fn sysReboot(args: [sys.MAXARGS]u64) u64 {
    if (kern_proc.current.euid != 0) return sys.signed(-errno.EPERM);
    kern_reboot(args[0]);
}
