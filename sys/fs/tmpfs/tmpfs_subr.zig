// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// tmpfs subroutines.
//
// This is the Zig counterpart of NetBSD's sys/fs/tmpfs/tmpfs_subr.c, reduced to
// node and directory-entry allocation, directory lookup, and the read/write
// paths for regular files. All storage comes from kmem.

const tmpfs: type = @import("tmpfs.zig");
const vnode: type = @import("../../sys/vnode.zig");
const namei: type = @import("../../sys/namei.zig");
const kern_time: type = @import("../../kern/kern_time.zig");
const kmem: type = @import("../../kern/subr_kmem.zig");

/// Allocate a node of `v_type`, with a fresh inode number.
pub fn allocNode(mnt: *tmpfs.TmpfsMount, v_type: vnode.Vtype) ?*tmpfs.Node {
    const node: *tmpfs.Node = kmem.zallocAs(tmpfs.Node) orelse return null;
    node.vnode = null;
    node.type = v_type;
    node.id = mnt.next_id;
    mnt.next_id += 1;
    node.size = 0;
    node.mode = 0o644;
    node.nlink = 1;
    node.rdev = 0;
    node.parent = null;
    node.entries = null;
    node.data_head = null;
    node.data_tail = null;
    node.nchunks = 0;
    // A new file is born now (the files unpacked from the root image too:
    // they come into existence at boot).
    const now: i64 = @intCast(kern_time.now());
    node.atime = now;
    node.mtime = now;
    node.ctime = now;
    return node;
}

/// Free every chunk of `node` and the node itself.
pub fn freeNode(node: *tmpfs.Node) void {
    var c: ?*tmpfs.Chunk = node.data_head;
    while (c) |chunk| {
        c = chunk.next;
        kmem.free(@ptrCast(chunk));
    }
    kmem.free(@ptrCast(node));
}

/// Allocate a directory entry whose name is a copy of `name`.
pub fn allocDirent(name: []const u8) ?*tmpfs.Dirent {
    if (name.len == 0 or name.len > tmpfs.MAXNAMLEN) {
        return null;
    }
    const de: *tmpfs.Dirent = kmem.zallocAs(tmpfs.Dirent) orelse return null;
    const buf: [*]u8 = @ptrCast(kmem.alloc(name.len) orelse {
        kmem.free(@ptrCast(de));
        return null;
    });
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        buf[i] = name[i];
    }
    de.name = buf[0..name.len];
    de.next = null;
    de.node = undefined;
    return de;
}

/// Free a directory entry and its name.
pub fn freeDirent(de: *tmpfs.Dirent) void {
    kmem.free(@ptrCast(de.name.ptr));
    kmem.free(@ptrCast(de));
}

/// Add `de` to the tail of directory `dir`'s entry list.
pub fn dirAttach(dir: *tmpfs.Node, de: *tmpfs.Dirent) void {
    de.next = null;
    if (dir.entries) |head| {
        var p: *tmpfs.Dirent = head;
        while (p.next) |n| {
            p = n;
        }
        p.next = de;
    } else {
        dir.entries = de;
    }
}

/// Remove `de` from directory `dir`'s entry list; true when it was found.
pub fn dirDetach(dir: *tmpfs.Node, de: *tmpfs.Dirent) bool {
    var prev: ?*tmpfs.Dirent = null;
    var p: ?*tmpfs.Dirent = dir.entries;
    while (p) |cur| : (p = cur.next) {
        if (cur == de) {
            if (prev) |pv| {
                pv.next = cur.next;
            } else {
                dir.entries = cur.next;
            }
            return true;
        }
        prev = cur;
    }
    return false;
}

/// Compare the component name in `cnp` with `name`.
fn nameMatches(cnp: *const namei.Componentname, name: []const u8) bool {
    if (cnp.namelen != name.len) {
        return false;
    }
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (cnp.nameptr[i] != name[i]) {
            return false;
        }
    }
    return true;
}

/// Find the entry named in `cnp` in directory `dir`, or null.
pub fn dirLookup(dir: *tmpfs.Node, cnp: *const namei.Componentname) ?*tmpfs.Dirent {
    var p: ?*tmpfs.Dirent = dir.entries;
    while (p) |de| : (p = de.next) {
        if (nameMatches(cnp, de.name)) {
            return de;
        }
    }
    return null;
}

/// The `index`-th entry of `dir`, counting from zero, or null.
pub fn nthEntry(dir: *tmpfs.Node, index: usize) ?*tmpfs.Dirent {
    var p: ?*tmpfs.Dirent = dir.entries;
    var n: usize = 0;
    while (p) |de| : (p = de.next) {
        if (n == index) {
            return de;
        }
        n += 1;
    }
    return null;
}

/// Return chunk `index` of `node`, or null when it does not exist.
/// Chunk `index` of `node` (it holds bytes [index*CHUNK_DATA, (index+1)*
/// CHUNK_DATA) of the file), or null past the last one. The walk starts at
/// the cursor when it can, so sequential access does not rescan the list.
fn chunkAt(node: *tmpfs.Node, index: usize) ?*tmpfs.Chunk {
    var c: ?*tmpfs.Chunk = node.data_head;
    var n: usize = 0;
    if (node.cur_chunk) |cur| {
        if (node.cur_index <= index) {
            c = cur;
            n = node.cur_index;
        }
    }
    while (c) |chunk| : (c = chunk.next) {
        if (n == index) {
            node.cur_chunk = chunk;
            node.cur_index = n;
            return chunk;
        }
        n += 1;
    }
    return null;
}

fn chunkAtOrAppend(node: *tmpfs.Node, index: usize) ?*tmpfs.Chunk {
    while (node.nchunks <= index) {
        const chunk: *tmpfs.Chunk = kmem.zallocAs(tmpfs.Chunk) orelse return null;
        chunk.next = null;
        chunk.len = 0;
        if (node.data_tail) |tail| {
            tail.next = chunk;
        } else {
            node.data_head = chunk;
        }
        node.data_tail = chunk;
        node.nchunks += 1;
    }
    return chunkAt(node, index);
}

/// Change the size of regular file `node` to `length`. Shrinking to zero
/// drops every chunk; a non-zero shrink trims the last partial chunk (extending
/// just grows the size, with holes read as zeroes).
pub fn regTruncate(node: *tmpfs.Node, length: u64) void {
    node.cur_chunk = null;
    node.cur_index = 0;
    if (length >= node.size) {
        node.size = length; // growing: the new bytes read as zeros
        return;
    }

    // Keep the chunks that hold bytes below `length`; free the rest.
    const keep: usize = @intCast((length + tmpfs.CHUNK_DATA - 1) / tmpfs.CHUNK_DATA);
    var prev: ?*tmpfs.Chunk = null;
    var c: ?*tmpfs.Chunk = node.data_head;
    var n: usize = 0;
    while (c != null and n < keep) : (n += 1) {
        prev = c;
        c = c.?.next;
    }
    while (c) |chunk| {
        const next: ?*tmpfs.Chunk = chunk.next;
        kmem.freeAs(tmpfs.Chunk, chunk);
        c = next;
    }
    if (prev) |last| {
        last.next = null;
        // Zero what the last chunk held past the new end, so growing the
        // file again reads zeros, not the old bytes.
        const used: usize = @intCast(length - (keep - 1) * tmpfs.CHUNK_DATA);
        if (used < last.len) @memset(last.data[used..last.len], 0);
        if (used < last.len) last.len = used;
    } else {
        node.data_head = null;
    }
    node.data_tail = prev;
    node.nchunks = @min(node.nchunks, keep);
    node.size = length;
}

/// Read up to `buf.len` bytes of regular file `node` starting at `offset`.
pub fn regRead(node: *tmpfs.Node, offset: u64, buf: []u8) usize {
    if (offset >= node.size) {
        return 0;
    }
    const total: usize = @intCast(@min(@as(u64, buf.len), node.size - offset));
    var done: usize = 0;
    while (done < total) {
        const pos: u64 = offset + done;
        const index: usize = @intCast(pos / tmpfs.CHUNK_DATA);
        const within: usize = @intCast(pos % tmpfs.CHUNK_DATA);
        const take: usize = @min(tmpfs.CHUNK_DATA - within, total - done);
        if (chunkAt(node, index)) |chunk| {
            // Chunk memory is zeroed when allocated, so a hole inside it
            // (bytes past chunk.len) reads as zeros.
            @memcpy(buf[done .. done + take], chunk.data[within .. within + take]);
        } else {
            @memset(buf[done .. done + take], 0); // a hole past the last chunk
        }
        done += take;
    }
    return done;
}

/// Write `buf` to regular file `node` at `offset`, growing the file as needed.
pub fn regWrite(node: *tmpfs.Node, offset: u64, buf: []const u8) usize {
    var written: usize = 0;
    while (written < buf.len) {
        const pos: u64 = offset + written;
        const index: usize = @intCast(pos / tmpfs.CHUNK_DATA);
        const within: usize = @intCast(pos % tmpfs.CHUNK_DATA);
        const chunk: *tmpfs.Chunk = chunkAtOrAppend(node, index) orelse break;
        const take: usize = @min(tmpfs.CHUNK_DATA - within, buf.len - written);
        @memcpy(chunk.data[within .. within + take], buf[written .. written + take]);
        written += take;
        if (within + take > chunk.len) {
            chunk.len = within + take;
        }
    }

    const end: u64 = offset + written;
    if (end > node.size) {
        node.size = end;
    }
    return written;
}
