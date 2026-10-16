// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// renux-installer: install Renux onto a disk, the way bsdinstall does.
//
// A menu-driven installer (dialog) that writes a GPT with an EFI system
// partition and an ext2 root, copies the images the kernel carries (/dev/md0
// is the root image, /dev/md1 the ESP image), and generates the installed
// system's /etc/fstab. Run with no arguments for the menu, or
// `renux-installer -y /dev/vda` to install unattended.
//
// The root image is already an ext2 filesystem, so installing is a byte copy
// of it onto the root partition -- no formatter runs on the target -- and the
// ESP image already holds the loader and the kernel.

const libc: type = @import("libc");
comptime {
    _ = @import("csu").crt0;
}

const sys = libc.syscall;

const SECTOR: u64 = 512;
const ESP_START: u64 = 2048; // 1 MiB in
const ESP_SECTORS: u64 = 131072; // 64 MiB
const ROOT_START: u64 = ESP_START + ESP_SECTORS;

const DIOCGMEDIASIZE: u64 = 0x40086481; // _IOR('d', 129, i64)

// GPT type GUIDs, as stored (mixed endian).
const ESP_TYPE: [16]u8 = .{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
const FS_TYPE: [16]u8 = .{ 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 };

var env_array = [_:null]?[*:0]const u8{
    "TERM=xterm",
    "PATH=/sbin:/bin:/usr/sbin:/usr/bin",
};
const ENV: [*]?[*:0]const u8 = @ptrCast(&env_array);

fn span(p: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return p[0..n];
}

fn openPath(path: [*:0]const u8, flags: u64) i64 {
    return sys.open(path, flags, 0);
}

fn writeAll(fd: u64, buf: []const u8) bool {
    var done: usize = 0;
    while (done < buf.len) {
        const n: u64 = sys.write(fd, buf[done..]);
        if (n == 0 or n > buf.len - done) return false;
        done += n;
    }
    return true;
}

fn pwrite(fd: u64, off: u64, buf: []const u8) bool {
    _ = sys.lseek(fd, @intCast(off), 0);
    return writeAll(fd, buf);
}

fn pread(fd: u64, off: u64, buf: []u8) void {
    _ = sys.lseek(fd, @intCast(off), 0);
    var done: usize = 0;
    while (done < buf.len) {
        const n: u64 = sys.read(fd, buf[done..]);
        if (n == 0) return;
        done += n;
    }
}

fn devSectors(fd: u64) u64 {
    var sz: i64 = 0;
    _ = sys.ioctl(fd, DIOCGMEDIASIZE, @intFromPtr(&sz));
    if (sz < 0) return 0;
    return @as(u64, @intCast(sz)) / SECTOR;
}

/// Fork, run `argv`, wait, and return the exit status.
fn run(argv: [*]?[*:0]const u8, stdout_fd: i64) i32 {
    const pid: i32 = sys.fork();
    if (pid == 0) {
        if (stdout_fd >= 0) {
            _ = sys.dup2(@intCast(stdout_fd), 1);
        }
        _ = sys.execve(argv[0].?, argv, ENV);
        sys.exit(127);
    }
    var status: i32 = 0;
    _ = sys.wait(&status);
    return status;
}

// -- dialog ------------------------------------------------------------------

var dlg_buf: [256]u8 = undefined;

/// Run dialog with `args` (after the program name); the UI goes to the
/// terminal, the chosen value is written to stdout, captured here. Returns the
/// value without its trailing newline, or null.
fn dialog(args: []const [*:0]const u8) ?[]const u8 {
    var argv: [16]?[*:0]const u8 = @splat(null);
    argv[0] = "/usr/bin/dialog";
    var i: usize = 0;
    while (i < args.len and i + 1 < argv.len) : (i += 1) argv[i + 1] = args[i];

    const out = openPath("/tmp/.renux-dlg", sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC);
    if (out < 0) return null;
    _ = run(@ptrCast(&argv), out);
    _ = sys.close(@intCast(out));

    const fd = openPath("/tmp/.renux-dlg", sys.O_RDONLY);
    if (fd < 0) return null;
    const n: u64 = sys.read(@intCast(fd), &dlg_buf);
    _ = sys.close(@intCast(fd));
    if (n == 0) return null;
    var len: usize = @intCast(n);
    while (len > 0 and (dlg_buf[len - 1] == '\n' or dlg_buf[len - 1] == '\r')) len -= 1;
    return dlg_buf[0..len];
}

fn msgbox(text: [*:0]const u8) void {
    _ = dialog(&.{ "--title", "Renux Installer", "--msgbox", text, "0", "0" });
}

fn yesno(text: [*:0]const u8) bool {
    const r = dialog(&.{ "--title", "Renux Installer", "--yesno", text, "0", "0" });
    return r != null;
}

// -- GPT ---------------------------------------------------------------------

fn crc32(buf: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (buf) |b| {
        crc ^= b;
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            crc = if ((crc & 1) != 0) (crc >> 1) ^ 0xEDB88320 else crc >> 1;
        }
    }
    return ~crc;
}

fn put16(b: []u8, o: usize, v: u16) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
}
fn put32(b: []u8, o: usize, v: u32) void {
    b[o] = @truncate(v);
    b[o + 1] = @truncate(v >> 8);
    b[o + 2] = @truncate(v >> 16);
    b[o + 3] = @truncate(v >> 24);
}
fn put64(b: []u8, o: usize, v: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) b[o + i] = @truncate(v >> @intCast(i * 8));
}

/// Write the protective MBR, the primary GPT and its backup for a disk with an
/// EFI system partition (1) and an ext2 root (2).
fn writeGpt(fd: u64, sectors: u64) void {
    const first_usable: u64 = 34;
    const last_usable: u64 = sectors - 34;
    const root_last: u64 = last_usable;
    if (sectors < ROOT_START + 2048) return;

    var entries: [128 * 128]u8 = @splat(0);
    // Partition 1: EFI system, FAT.
    @memcpy(entries[0..16], &ESP_TYPE);
    entries[16] = 1; // unique GUID (a simple marker is enough for us)
    put64(&entries, 32, ESP_START);
    put64(&entries, 40, ESP_START + ESP_SECTORS - 1);
    const esp_name = "EFI System";
    for (esp_name, 0..) |ch, i| entries[56 + i * 2] = ch;
    // Partition 2: root, ext2.
    @memcpy(entries[128 .. 128 + 16], &FS_TYPE);
    entries[144] = 2;
    put64(&entries, 128 + 32, ROOT_START);
    put64(&entries, 128 + 40, root_last);
    const root_name = "Renux root";
    for (root_name, 0..) |ch, i| entries[128 + 56 + i * 2] = ch;

    const entries_crc = crc32(&entries);
    const entries_sectors: u64 = 32;

    var hdr: [512]u8 = @splat(0);
    @memcpy(hdr[0..8], "EFI PART");
    put32(&hdr, 8, 0x00010000);
    put32(&hdr, 12, 92);
    put64(&hdr, 24, 1);
    put64(&hdr, 32, sectors - 1);
    put64(&hdr, 40, first_usable);
    put64(&hdr, 48, last_usable);
    hdr[56] = 0x52; // disk GUID marker
    put64(&hdr, 72, 2);
    put32(&hdr, 80, 128);
    put32(&hdr, 84, 128);
    put32(&hdr, 88, entries_crc);
    put32(&hdr, 16, crc32(hdr[0..92]));

    // Protective MBR.
    var mbr: [512]u8 = @splat(0);
    const cover: u32 = if (sectors - 1 > 0xFFFFFFFF) 0xFFFFFFFF else @intCast(sectors - 1);
    mbr[446 + 4] = 0xEE;
    put32(&mbr, 446 + 8, 1);
    put32(&mbr, 446 + 12, cover);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;

    _ = pwrite(fd, 0, &mbr);
    _ = pwrite(fd, SECTOR, &hdr);
    _ = pwrite(fd, 2 * SECTOR, &entries);

    // Backup: entries then header at the end of the disk.
    const bkp_entries_lba = sectors - 1 - entries_sectors;
    var bhdr: [512]u8 = @splat(0);
    @memcpy(bhdr[0..8], "EFI PART");
    put32(&bhdr, 8, 0x00010000);
    put32(&bhdr, 12, 92);
    put64(&bhdr, 24, sectors - 1);
    put64(&bhdr, 32, 1);
    put64(&bhdr, 40, first_usable);
    put64(&bhdr, 48, last_usable);
    bhdr[56] = 0x52;
    put64(&bhdr, 72, bkp_entries_lba);
    put32(&bhdr, 80, 128);
    put32(&bhdr, 84, 128);
    put32(&bhdr, 88, entries_crc);
    put32(&bhdr, 16, crc32(bhdr[0..92]));
    _ = pwrite(fd, bkp_entries_lba * SECTOR, &entries);
    _ = pwrite(fd, (sectors - 1) * SECTOR, &bhdr);
}

/// Copy the whole of `src` (a path) to `fd` at byte offset `dst_off`. The
/// source is a memory disk, so its size comes from the device.
fn copyImage(src_path: [*:0]const u8, fd: u64, dst_off: u64, max: u64) u64 {
    const src = openPath(src_path, sys.O_RDONLY);
    if (src < 0) return 0;
    var sz: i64 = 0;
    _ = sys.ioctl(@intCast(src), DIOCGMEDIASIZE, @intFromPtr(&sz));
    var total: u64 = @intCast(@max(sz, 0));
    if (total > max) total = max;
    var buf: [256 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (off < total) {
        const want: usize = @intCast(@min(@as(u64, buf.len), total - off));
        const lr: i64 = sys.lseek(@intCast(src), @intCast(off), 0);
        if (lr < 0) {
            libc.stdio.printf("installer: lseek on %s failed (%d)\n", .{ span(src_path), lr });
            break;
        }
        const got: u64 = sys.read(@intCast(src), buf[0..want]);
        if (got == 0 or got > want) {
            libc.stdio.printf("installer: read %s returned %u (want %u, off %u)\n", .{ span(src_path), got, want, off });
            break;
        }
        if (!pwrite(fd, dst_off + off, buf[0..@intCast(got)])) {
            libc.stdio.printf("installer: write to the target failed at offset %u\n", .{dst_off + off});
            break;
        }
        off += got;
    }
    _ = sys.close(@intCast(src));
    return off;
}

// -- the installed fstab -----------------------------------------------------
//
// The root image is copied byte for byte, so its /etc/fstab is rewritten here,
// in place, by walking the ext2 directory tree on the target and overwriting
// the file's first block. Only direct blocks are needed for / and /etc.

const Ext2 = struct {
    fd: u64,
    base: u64, // byte offset of the filesystem
    bs: u32,
    itable: u64, // block of the first inode table
    ipg: u32,

    fn readAt(self: Ext2, off: u64, buf: []u8) void {
        pread(self.fd, self.base + off, buf);
    }
    fn writeAt(self: Ext2, off: u64, buf: []const u8) void {
        _ = pwrite(self.fd, self.base + off, buf);
    }
    fn inodeOff(self: Ext2, ino: u32, inode_size: u32) u64 {
        return self.itable * self.bs + @as(u64, ino - 1) * inode_size;
    }
};

/// Look up `name` in the directory inode `dir_ino`; returns its inode number.
fn dirLookup(x: Ext2, dir_ino: u32, inode_size: u32, name: []const u8) ?u32 {
    var ino_buf: [256]u8 = undefined;
    x.readAt(x.inodeOff(dir_ino, inode_size), ino_buf[0..inode_size]);
    var block: u64 = 0;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const b = @as(u32, ino_buf[40 + i * 4]) | (@as(u32, ino_buf[40 + i * 4 + 1]) << 8) |
            (@as(u32, ino_buf[40 + i * 4 + 2]) << 16) | (@as(u32, ino_buf[40 + i * 4 + 3]) << 24);
        if (b != 0) {
            block = b;
            break;
        }
    }
    if (block == 0) return null;
    var blk: [4096]u8 = undefined;
    const bs: usize = x.bs;
    x.readAt(block * bs, blk[0..bs]);
    var pos: usize = 0;
    while (pos + 8 <= bs) {
        const ent_ino = @as(u32, blk[pos]) | (@as(u32, blk[pos + 1]) << 8) | (@as(u32, blk[pos + 2]) << 16) | (@as(u32, blk[pos + 3]) << 24);
        const reclen = @as(u16, blk[pos + 4]) | (@as(u16, blk[pos + 5]) << 8);
        const namlen: usize = blk[pos + 6];
        if (reclen == 0) break;
        if (ent_ino != 0 and namlen == name.len and eql(blk[pos + 8 .. pos + 8 + namlen], name)) return ent_ino;
        pos += reclen;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// Overwrite /etc/fstab inside the (already copied) root filesystem with
/// `content`, truncating it to the new length.
fn writeFstab(fd: u64, base: u64, content: []const u8) bool {
    var sb: [1024]u8 = undefined;
    pread(fd, base + 1024, &sb);
    if ((sb[56] | (@as(u16, sb[57]) << 8)) != 0xEF53) return false; // magic
    const log_bs: u32 = @as(u32, sb[24]) | (@as(u32, sb[25]) << 8) | (@as(u32, sb[26]) << 16) | (@as(u32, sb[27]) << 24);
    const inode_size: u32 = @as(u16, sb[88]) | (@as(u16, sb[89]) << 8);
    const first_data: u32 = @as(u32, sb[20]) | (@as(u32, sb[21]) << 8) | (@as(u32, sb[22]) << 16) | (@as(u32, sb[23]) << 24);
    const gd_off: u64 = (@as(u64, first_data) + 1) * (@as(u64, 1024) << @intCast(log_bs));
    var gd: [32]u8 = undefined;
    pread(fd, base + gd_off, &gd);
    const itable: u64 = @as(u32, gd[8]) | (@as(u32, gd[9]) << 8) | (@as(u32, gd[10]) << 16) | (@as(u32, gd[11]) << 24);
    const ipg: u32 = @as(u32, sb[40]) | (@as(u32, sb[41]) << 8) | (@as(u32, sb[42]) << 16) | (@as(u32, sb[43]) << 24);

    const x: Ext2 = .{ .fd = fd, .base = base, .bs = @as(u32, 1024) << @intCast(log_bs), .itable = itable, .ipg = ipg };
    const etc = dirLookup(x, 2, inode_size, "etc") orelse return false;
    const fstab = dirLookup(x, etc, inode_size, "fstab") orelse return false;

    // The file's first direct block.
    var ino_buf: [256]u8 = undefined;
    const io = x.inodeOff(fstab, inode_size);
    x.readAt(io, ino_buf[0..inode_size]);
    const data_block: u32 = @as(u32, ino_buf[40]) | (@as(u32, ino_buf[41]) << 8) | (@as(u32, ino_buf[42]) << 16) | (@as(u32, ino_buf[43]) << 24);
    if (data_block == 0 or content.len > x.bs) return false;
    var blk: [1024]u8 = @splat(0);
    @memcpy(blk[0..content.len], content);
    x.writeAt(data_block * x.bs, blk[0..x.bs]);
    // i_size, and one block counted in i_blocks.
    put32(ino_buf[0..], 4, @intCast(content.len));
    put32(ino_buf[0..], 28, x.bs / 512);
    x.writeAt(io, ino_buf[0..inode_size]);
    return true;
}

// -- the install -------------------------------------------------------------

const FSTAB =
    "# Device\tMountpoint\tFStype\tOptions\t\tDump\tPass#\n" ++
    "# Written by the Renux installer. The root is named by the loader\n" ++
    "# (vfs.root.mountfrom); the EFI system partition is /dev/vda1.\n" ++
    "#/dev/vda2\t/\t\text2fs\trw\t\t0\t1\n";

fn install(dev: [*:0]const u8) bool {
    const fd = openPath(dev, sys.O_RDWR);
    if (fd < 0) {
        libc.stdio.printf("installer: cannot open %s\n", .{span(dev)});
        return false;
    }
    const sectors = devSectors(@intCast(fd));
    if (sectors < ROOT_START + 4096) {
        libc.stdio.printf("installer: %s is too small\n", .{span(dev)});
        return false;
    }

    libc.stdio.printf("installer: writing the GPT on %s\n", .{span(dev)});
    writeGpt(@intCast(fd), sectors);

    libc.stdio.printf("installer: copying the root image\n", .{});
    _ = copyImage("/dev/md0", @intCast(fd), ROOT_START * SECTOR, (sectors - 34 - ROOT_START) * SECTOR);

    libc.stdio.printf("installer: writing the EFI system partition\n", .{});
    _ = copyImage("/dev/md1", @intCast(fd), ESP_START * SECTOR, ESP_SECTORS * SECTOR);

    libc.stdio.printf("installer: generating /etc/fstab\n", .{});
    if (!writeFstab(@intCast(fd), ROOT_START * SECTOR, FSTAB)) {
        libc.stdio.printf("installer: warning: could not rewrite /etc/fstab\n", .{});
    }

    _ = sys.close(@intCast(fd));
    libc.stdio.printf("installer: done.\n", .{});
    return true;
}

export fn main(argc: i32, argv: [*]?[*:0]const u8) callconv(.c) i32 {
    if (argc >= 3 and span(argv[1].?).len == 2 and span(argv[1].?)[0] == '-' and span(argv[1].?)[1] == 'y') {
        return if (install(argv[2].?)) 0 else 1;
    }

    // The bsdinstall-style flow.
    if (!yesno("Welcome to Renux.\n\nThis will install Renux onto a disk.\nProceed?")) return 0;

    const disks = [_][*:0]const u8{ "/dev/vda", "/dev/vdb", "/dev/sda", "/dev/sdb" };
    var tags: [4][*:0]const u8 = undefined;
    var descs: [4][*:0]const u8 = undefined;
    var n: usize = 0;
    for (disks) |d| {
        const fd = openPath(d, sys.O_RDONLY);
        if (fd < 0) continue;
        _ = sys.close(@intCast(fd));
        tags[n] = d;
        descs[n] = d;
        n += 1;
    }
    if (n == 0) {
        msgbox("No disk found (/dev/vda, /dev/sda, ...).");
        return 1;
    }
    if (n == 1) {
        if (!yesno("The only disk found will be erased and Renux installed onto it. Continue?")) return 0;
        return if (install(tags[0])) 0 else 1;
    }

    var menu: [16][*:0]const u8 = undefined;
    menu[0] = "--title";
    menu[1] = "Choose a disk";
    menu[2] = "--menu";
    menu[3] = "Install Renux onto which disk?";
    menu[4] = "0";
    menu[5] = "0";
    menu[6] = "0";
    var i: usize = 0;
    while (i < n and 7 + i * 2 + 1 < menu.len) : (i += 1) {
        menu[7 + i * 2] = tags[i];
        menu[8 + i * 2] = descs[i];
    }
    const chosen = dialog(menu[0 .. 7 + n * 2]);
    if (chosen == null) return 0;
    var path: [64]u8 = undefined;
    @memcpy(path[0..chosen.?.len], chosen.?);
    path[chosen.?.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&path);
    if (!yesno("All data on the chosen disk will be lost. Install?")) return 0;
    return if (install(p)) 0 else 1;
}
