// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Filesystem registry and mount bookkeeping.
//
// This is the Zig counterpart of FreeBSD's sys/kern/vfs_init.c and
// vfs_mount.c: filesystems register a Vfs record, mounting one creates a
// Mount that remembers the filesystem's private data, its root vnode and the
// directory it covers, and nmount(2)/unmount(2) attach and detach
// filesystems at run time. The root filesystem is the one namei() starts
// from.

const vnode: type = @import("../sys/vnode.zig");
const mount: type = @import("../sys/mount.zig");
const errno: type = @import("../sys/errno.zig");
const sys: type = @import("../sys/syscall.zig");
const geom_disk: type = @import("../geom/geom_disk.zig");
const prf: type = @import("subr_prf.zig");
const kern_proc: type = @import("kern_proc.zig");
const vfs_lookup: type = @import("vfs_lookup.zig");
const vfs_bio: type = @import("vfs_bio.zig");
const subr_syscall: type = @import("subr_syscall.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const file: type = @import("../sys/file.zig");

/// Maximum number of simultaneously mounted filesystems.
pub const MAXMOUNT: usize = 8;

/// Head of the list of registered filesystem types.
var vfs_list: ?*mount.Vfs = null;

/// Mounted filesystems.
var mounts: [MAXMOUNT]mount.Mount = undefined;
var mounts_init: bool = false;

/// The filesystem mounted as the system root.
var rootmount: ?*mount.Mount = null;

/// Register a filesystem type. Called once per filesystem, at SI_SUB_VFS.
pub fn register(vfs: *mount.Vfs) void {
    vfs.next = vfs_list;
    vfs_list = vfs;
}

/// Compare two names for equality.
fn nameEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Find a registered filesystem by name.
pub fn find(name: []const u8) ?*mount.Vfs {
    var p: ?*mount.Vfs = vfs_list;
    while (p) |vfs| : (p = vfs.next) {
        if (nameEqual(vfs.name, name)) return vfs;
    }
    return null;
}

fn setName(dst: *[mount.MNAMELEN]u8, src: []const u8) void {
    @memset(dst, 0);
    const n: usize = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
}

fn cstrLen(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and s[n] != 0) n += 1;
    return n;
}

/// Mount the filesystem named `name`, passing `data` to its mount routine.
/// Returns the new Mount, or null on failure (the error in `err`).
fn mountFsErr(name: []const u8, data: ?*anyopaque, flags: u64, err: *i32) ?*mount.Mount {
    if (!mounts_init) {
        for (&mounts) |*m| m.mnt_used = false;
        mounts_init = true;
    }
    const vfs: *mount.Vfs = find(name) orelse {
        err.* = errno.ENODEV;
        return null;
    };
    var slot: ?*mount.Mount = null;
    for (&mounts) |*m| {
        if (!m.mnt_used) {
            slot = m;
            break;
        }
    }
    const mp: *mount.Mount = slot orelse {
        err.* = errno.ENOMEM;
        return null;
    };
    mp.* = .{
        .mnt_op = vfs.ops,
        .mnt_vfc = vfs,
        .mnt_data = null,
        .mnt_root = null,
        .mnt_flag = flags,
        .mnt_name = vfs.name,
    };
    const e: i32 = vfs.ops.mount(mp, data);
    if (e != 0) {
        err.* = e;
        return null;
    }
    var vp: ?*vnode.Vnode = null;
    if (vfs.ops.root(mp, &vp) != 0) {
        _ = vfs.ops.unmount(mp, mount.MNT_FORCE);
        err.* = errno.EIO;
        return null;
    }
    const root: *vnode.Vnode = vp orelse {
        err.* = errno.EIO;
        return null;
    };
    root.v_flag |= vnode.VROOT;
    mp.mnt_root = root;
    mp.mnt_used = true;
    prf.log(prf.LOG_INFO, "%s: mounted", .{name});
    return mp;
}

/// Mount the filesystem named `name`, passing `data` to its mount routine.
/// Returns the new Mount, or null on failure.
pub fn mountFs(name: []const u8, data: ?*anyopaque) ?*mount.Mount {
    var err: i32 = 0;
    return mountFsErr(name, data, mount.MNT_LOCAL, &err);
}

/// Record `mp` as the system root filesystem.
pub fn setRoot(mp: *mount.Mount) void {
    rootmount = mp;
    mp.mnt_flag |= mount.MNT_ROOTFS;
    setName(&mp.mnt_onname, "/");
    if (mp.mnt_fromname[0] == 0) setName(&mp.mnt_fromname, mp.mnt_name);
}

/// Mount the filesystem `name` on the directory `dir`: the new filesystem's
/// root is reached whenever namei() descends through `dir`. Returns the
/// mount, or null.
pub fn mountOn(dir: *vnode.Vnode, name: []const u8, data: ?*anyopaque) ?*mount.Mount {
    if (dir.v_type != .vdir) return null;
    const mp: *mount.Mount = mountFs(name, data) orelse return null;
    dir.v_mountedhere = mp;
    mp.mnt_vnodecovered = dir;
    return mp;
}

/// Follow a mount point: if `vp` is a directory a filesystem is mounted on,
/// return that filesystem's root; otherwise return `vp`.
pub fn cross(vp: *vnode.Vnode) *vnode.Vnode {
    var v: *vnode.Vnode = vp;
    var guard: usize = 0;
    while (v.v_mountedhere) |m| {
        const root: ?*vnode.Vnode = m.mnt_root;
        if (root == null or guard >= 8) break;
        v = root.?;
        guard += 1;
    }
    return v;
}

/// For ".." at the root of a mounted filesystem: the directory it covers
/// (so the lookup continues in the filesystem above), else `vp` itself.
pub fn uncover(vp: *vnode.Vnode) *vnode.Vnode {
    var v: *vnode.Vnode = vp;
    var guard: usize = 0;
    while ((v.v_flag & vnode.VROOT) != 0 and guard < 8) : (guard += 1) {
        const mp: *mount.Mount = v.v_mount orelse break;
        v = mp.mnt_vnodecovered orelse break;
    }
    return v;
}

/// The root vnode of the system, or null before root is mounted.
pub fn getRoot() ?*vnode.Vnode {
    const mp: *mount.Mount = rootmount orelse return null;
    return mp.mnt_root;
}

/// The mounted filesystems, root first.
fn eachMount(i: usize) ?*mount.Mount {
    var n: usize = 0;
    if (rootmount) |r| {
        if (i == 0) return r;
        n = 1;
    }
    for (&mounts) |*m| {
        if (!m.mnt_used or m == rootmount) continue;
        if (n == i) return m;
        n += 1;
    }
    return null;
}

/// Whether the filesystem on `dp` is in the middle of an operation (the
/// syncer leaves its buffers alone until it is done).
pub fn diskBusy(dp: *geom_disk.Disk) bool {
    for (&mounts) |*m| {
        if (!m.mnt_used or m.mnt_disk != dp) continue;
        if (m.mnt_op.busy) |b| {
            if (b(m)) return true;
        }
    }
    return false;
}

/// Whether some filesystem is mounted from `dp`.
fn diskMounted(dp: *geom_disk.Disk) bool {
    for (&mounts) |*m| {
        if (m.mnt_used and m.mnt_disk == dp) return true;
    }
    return false;
}

/// Write out every mounted filesystem (sync(2), and before a reboot).
pub fn syncAll() void {
    for (&mounts) |*m| {
        if (!m.mnt_used) continue;
        if (m.mnt_op.sync) |s| _ = s(m);
    }
    _ = vfs_bio.bflush(null);
}

/// The filesystem id of `mp` (f_fsid): its slot and type, stable while it
/// stays mounted.
fn fsidOf(mp: *const mount.Mount) [2]i32 {
    const slot: usize = (@intFromPtr(mp) - @intFromPtr(&mounts)) / @sizeOf(mount.Mount);
    const typenum: u32 = if (mp.mnt_vfc) |v| v.typenum else 0;
    return .{ @intCast(0x5245_0000 | slot), @intCast(typenum) };
}

/// Parse "FSID:<val0>:<val1>", the name umount(8) passes with MNT_BYFSID.
fn parseFsid(s: []const u8) ?[2]i32 {
    const prefix: []const u8 = "FSID:";
    if (s.len <= prefix.len or !nameEqual(s[0..prefix.len], prefix)) return null;
    var out: [2]i32 = .{ 0, 0 };
    var k: usize = 0;
    var i: usize = prefix.len;
    while (k < 2) : (k += 1) {
        var neg: bool = false;
        if (i < s.len and s[i] == '-') {
            neg = true;
            i += 1;
        }
        var v: i64 = 0;
        const start: usize = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) v = v * 10 + (s[i] - '0');
        if (i == start) return null;
        out[k] = @truncate(if (neg) -v else v);
        if (k == 0) {
            if (i >= s.len or s[i] != ':') return null;
            i += 1;
        }
    }
    return out;
}

/// Unmount every filesystem but the root, deepest first, so disks are left
/// clean before a reboot (FreeBSD's vfs_unmountall()).
pub fn unmountAll() void {
    var pass: usize = 0;
    while (pass < MAXMOUNT) : (pass += 1) {
        var any: bool = false;
        for (&mounts) |*m| {
            if (!m.mnt_used or m == rootmount) continue;
            // Something else mounted inside goes first.
            var covered: bool = false;
            for (&mounts) |*o| {
                if (!o.mnt_used or o == m) continue;
                if (o.mnt_vnodecovered) |c| {
                    if (c.v_mount == m) covered = true;
                }
            }
            if (covered) continue;
            if (m.mnt_op.unmount(m, mount.MNT_FORCE) == 0) {
                if (m.mnt_vnodecovered) |c| c.v_mountedhere = null;
                m.mnt_used = false;
            }
            any = true;
        }
        if (!any) break;
    }
}

/// Fill `sbp` for `mp`.
fn fillStatfs(mp: *mount.Mount, sbp: *mount.Statfs) i32 {
    const raw: [*]u8 = @ptrCast(sbp);
    @memset(raw[0..@sizeOf(mount.Statfs)], 0);
    sbp.f_version = mount.STATFS_VERSION;
    const e: i32 = mp.mnt_op.statfs(mp, sbp);
    if (e != 0) return e;
    sbp.f_flags = mp.mnt_flag;
    if (mp.mnt_vfc) |vfc| sbp.f_type = vfc.typenum;
    sbp.f_fsid = fsidOf(mp);
    const n: usize = @min(mp.mnt_name.len, mount.MFSNAMELEN - 1);
    @memcpy(sbp.f_fstypename[0..n], mp.mnt_name[0..n]);
    sbp.f_mntfromname = mp.mnt_fromname;
    sbp.f_mntonname = mp.mnt_onname;
    return 0;
}

// -- system calls ------------------------------------------------------------------

/// struct iovec.
const Iovec: type = extern struct {
    base: u64,
    len: u64,
};

/// The option `name` of an nmount(2) argument vector: its value (without
/// the trailing NUL), or null when absent. A present option with no value
/// gives an empty slice.
fn iovOpt(iov: []align(1) const Iovec, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < iov.len) : (i += 2) {
        if (iov[i].base == 0) continue;
        const nm: [*]const u8 = @ptrFromInt(iov[i].base);
        const nlen: usize = cstrLen(nm[0..@intCast(iov[i].len)]);
        if (!nameEqual(nm[0..nlen], name)) continue;
        if (iov[i + 1].base == 0 or iov[i + 1].len == 0) return &.{};
        const v: [*]const u8 = @ptrFromInt(iov[i + 1].base);
        return v[0..cstrLen(v[0..@intCast(iov[i + 1].len)])];
    }
    return null;
}

/// Give the caller an error message through the "errmsg" option.
fn iovErrmsg(iov: []align(1) const Iovec, msg: []const u8) void {
    var i: usize = 0;
    while (i + 1 < iov.len) : (i += 2) {
        if (iov[i].base == 0) continue;
        const nm: [*]const u8 = @ptrFromInt(iov[i].base);
        if (!nameEqual(nm[0..cstrLen(nm[0..@intCast(iov[i].len)])], "errmsg")) continue;
        if (iov[i + 1].base == 0 or iov[i + 1].len == 0) return;
        const dst: [*]u8 = @ptrFromInt(iov[i + 1].base);
        const n: usize = @min(msg.len, @as(usize, @intCast(iov[i + 1].len)) - 1);
        @memcpy(dst[0..n], msg[0..n]);
        dst[n] = 0;
        return;
    }
}

/// nmount(2): `nmount(iov, niov, flags)`. The options name the filesystem
/// type ("fstype"), the directory ("fspath") and the device ("from");
/// "ro" mounts read-only.
pub fn sysNmount(args: [sys.MAXARGS]u64) u64 {
    if (kern_proc.current.euid != 0) return sys.signed(-errno.EPERM);
    const niov: u64 = args[1];
    if (niov == 0 or niov > 64 or niov % 2 != 0) return sys.signed(-errno.EINVAL);
    const iov: []align(1) const Iovec = @as([*]align(1) const Iovec, @ptrFromInt(args[0]))[0..@intCast(niov)];
    var flags: u64 = args[2] & (mount.MNT_RDONLY | mount.MNT_NOEXEC | mount.MNT_NOSUID | mount.MNT_SYNCHRONOUS);

    const fstype: []const u8 = iovOpt(iov, "fstype") orelse return sys.signed(-errno.EINVAL);
    const fspath: []const u8 = iovOpt(iov, "fspath") orelse return sys.signed(-errno.EINVAL);
    if (iovOpt(iov, "ro") != null or iovOpt(iov, "rdonly") != null) flags |= mount.MNT_RDONLY;
    if ((args[2] & mount.MNT_UPDATE) != 0) {
        iovErrmsg(iov, "updating a mount is not supported");
        return sys.signed(-errno.EOPNOTSUPP);
    }

    const dir: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, fspath) orelse return sys.signed(-errno.ENOENT);
    if (dir.v_type != .vdir) return sys.signed(-errno.ENOTDIR);
    if (dir.v_mountedhere != null or (dir.v_flag & vnode.VROOT) != 0) return sys.signed(-errno.EBUSY);

    var mp: *mount.Mount = undefined;
    var err: i32 = 0;
    if (nameEqual(fstype, "ext2fs")) {
        const from: []const u8 = iovOpt(iov, "from") orelse return sys.signed(-errno.EINVAL);
        const dvp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, from) orelse {
            iovErrmsg(iov, "no such device");
            return sys.signed(-errno.ENOENT);
        };
        if (dvp.v_type != .vchr) return sys.signed(-errno.ENOTBLK);
        var va: vnode.Vattr = undefined;
        if (dvp.v_op.getattr(dvp, &va) != 0) return sys.signed(-errno.EIO);
        const dp: *geom_disk.Disk = geom_disk.fromDev(va.rdev) orelse {
            iovErrmsg(iov, "not a disk");
            return sys.signed(-errno.ENXIO);
        };
        if (diskMounted(dp)) return sys.signed(-errno.EBUSY);
        var ext2_args = @import("../fs/ext2fs/ext2fs.zig").Args{ .disk = dp, .readonly = (flags & mount.MNT_RDONLY) != 0 };
        mp = mountFsErr("ext2fs", &ext2_args, flags | mount.MNT_LOCAL, &err) orelse {
            if (err == errno.EINVAL) iovErrmsg(iov, "no ext2 file system on this device");
            return sys.signed(-err);
        };
        mp.mnt_disk = dp;
        setName(&mp.mnt_fromname, from);
    } else if (nameEqual(fstype, "tmpfs")) {
        mp = mountFsErr("tmpfs", null, flags | mount.MNT_LOCAL, &err) orelse return sys.signed(-err);
        setName(&mp.mnt_fromname, "tmpfs");
    } else {
        iovErrmsg(iov, "unknown file system type");
        return sys.signed(-errno.ENODEV);
    }
    dir.v_mountedhere = mp;
    mp.mnt_vnodecovered = dir;
    // The absolute path of the mount point, as the caller gave it (mount(8)
    // passes a resolved path).
    setName(&mp.mnt_onname, fspath);
    return 0;
}

/// unmount(2): `unmount(path, flags)`.
pub fn sysUnmount(args: [sys.MAXARGS]u64) u64 {
    if (kern_proc.current.euid != 0) return sys.signed(-errno.EPERM);
    const path: []const u8 = subr_syscall.userStr(args[0]) orelse return sys.signed(-errno.EFAULT);
    var mp: *mount.Mount = undefined;
    if ((args[1] & mount.MNT_BYFSID) != 0) {
        // umount(8) names the filesystem by its id first.
        const fsid: [2]i32 = parseFsid(path) orelse return sys.signed(-errno.EINVAL);
        var found: ?*mount.Mount = null;
        for (&mounts) |*m| {
            if (!m.mnt_used) continue;
            const id: [2]i32 = fsidOf(m);
            if (id[0] == fsid[0] and id[1] == fsid[1]) found = m;
        }
        mp = found orelse return sys.signed(-errno.ENOENT);
    } else {
        const vp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);
        if ((vp.v_flag & vnode.VROOT) == 0) return sys.signed(-errno.EINVAL);
        mp = vp.v_mount orelse return sys.signed(-errno.EINVAL);
    }
    if (mp == rootmount) return sys.signed(-errno.EBUSY);
    // A filesystem with another mounted inside it stays.
    for (&mounts) |*m| {
        if (!m.mnt_used or m == mp) continue;
        if (m.mnt_vnodecovered) |c| {
            if (c.v_mount == mp) return sys.signed(-errno.EBUSY);
        }
    }
    // A process whose working directory is inside keeps it busy.
    if ((args[1] & mount.MNT_FORCE) == 0) {
        for (&kern_proc.table) |*p| {
            if (p.state == .unused or p.state == .zombie) continue;
            if (p.cwd) |c| {
                if (c.v_mount == mp) return sys.signed(-errno.EBUSY);
            }
        }
    }
    const e: i32 = mp.mnt_op.unmount(mp, args[1]);
    if (e != 0) return sys.signed(-e);
    if (mp.mnt_vnodecovered) |c| c.v_mountedhere = null;
    mp.mnt_used = false;
    return 0;
}

/// statfs(2): `statfs(path, buf)`.
pub fn sysStatfs(args: [sys.MAXARGS]u64) u64 {
    const path: []const u8 = subr_syscall.userStr(args[0]) orelse return sys.signed(-errno.EFAULT);
    const vp: *vnode.Vnode = vfs_lookup.nameiAt(kern_proc.current.cwd, path) orelse return sys.signed(-errno.ENOENT);
    const mp: *mount.Mount = vp.v_mount orelse return sys.signed(-errno.EINVAL);
    const e: i32 = fillStatfs(mp, @ptrFromInt(args[1]));
    return if (e == 0) 0 else sys.signed(-e);
}

/// fstatfs(2): `fstatfs(fd, buf)`.
pub fn sysFstatfs(args: [sys.MAXARGS]u64) u64 {
    const f: *file.File = kern_descrip.fdGetfile(kern_proc.current, @intCast(args[0])) orelse return sys.signed(-errno.EBADF);
    // Pipes, sockets and devices live on no filesystem of their own: report
    // the root, as devfs and pipefs would report themselves.
    var mp: ?*mount.Mount = rootmount;
    if (f.f_type == file.DTYPE_VNODE and f.f_ops == &@import("vfs_vnops.zig").vnode_ops) {
        const vp: *vnode.Vnode = @ptrCast(@alignCast(f.f_data orelse return sys.signed(-errno.EBADF)));
        if (vp.v_mount) |m| mp = m;
    }
    const e: i32 = fillStatfs(mp orelse return sys.signed(-errno.EINVAL), @ptrFromInt(args[1]));
    return if (e == 0) 0 else sys.signed(-e);
}

/// getfsstat(2): `getfsstat(buf, bufsize, mode)`. With a null buffer it
/// counts the mounted filesystems.
pub fn sysGetfsstat(args: [sys.MAXARGS]u64) u64 {
    const max: u64 = args[1] / @sizeOf(mount.Statfs);
    var n: u64 = 0;
    var i: usize = 0;
    while (eachMount(i)) |mp| : (i += 1) {
        if (args[0] != 0) {
            if (n >= max) break;
            const dst: *mount.Statfs = @ptrFromInt(args[0] + n * @sizeOf(mount.Statfs));
            if (fillStatfs(mp, dst) != 0) continue;
        }
        n += 1;
    }
    return n;
}

/// sync(2): write out every filesystem.
pub fn sysSync(args: [sys.MAXARGS]u64) u64 {
    _ = args;
    syncAll();
    return 0;
}
