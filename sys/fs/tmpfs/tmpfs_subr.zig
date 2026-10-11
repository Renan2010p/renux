// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// tmpfs subroutines.
//
// This is the Zig counterpart of NetBSD's sys/fs/tmpfs/tmpfs_subr.c, reduced to
// node and directory-entry allocation, directory lookup, and the read/write
// paths for regular files. All storage comes from kmem.

const tmpfs: type = @import("tmpfs.zig");
const vnode: type = @import("../../sys/vnode.zig");
const namei: type = @import("../../sys/namei.zig");
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
    node.parent = null;
    node.entries = null;
    node.data_head = null;
    node.data_tail = null;
    node.nchunks = 0;
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
fn chunkAt(node: *tmpfs.Node, index: usize) ?*tmpfs.Chunk {
    var c: ?*tmpfs.Chunk = node.data_head;
    var n: usize = 0;
    while (c) |chunk| : (c = chunk.next) {
        if (n == index) {
            return chunk;
        }
        n += 1;
    }
    return null;
}

/// Return chunk `index` of `node`, appending empty chunks until it exists.
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

/// Read up to `buf.len` bytes of regular file `node` starting at `offset`.
pub fn regRead(node: *tmpfs.Node, offset: u64, buf: []u8) usize {
    var copied: usize = 0;
    var base: u64 = 0;
    var c: ?*tmpfs.Chunk = node.data_head;
    while (c) |chunk| : (c = chunk.next) {
        const start: u64 = base;
        const end: u64 = base + chunk.len;
        base = end;
        if (offset >= end) {
            continue;
        }
        const skip: usize = if (offset > start) @intCast(offset - start) else 0;
        var i: usize = skip;
        while (i < chunk.len and copied < buf.len) : (i += 1) {
            buf[copied] = chunk.data[i];
            copied += 1;
        }
        if (copied == buf.len) {
            break;
        }
    }
    return copied;
}

/// Write `buf` to regular file `node` at `offset`, growing the file as needed.
pub fn regWrite(node: *tmpfs.Node, offset: u64, buf: []const u8) usize {
    var written: usize = 0;
    while (written < buf.len) {
        const pos: u64 = offset + written;
        const index: usize = @intCast(pos / tmpfs.CHUNK_DATA);
        const within: usize = @intCast(pos % tmpfs.CHUNK_DATA);

        const chunk: *tmpfs.Chunk = chunkAtOrAppend(node, index) orelse break;

        var i: usize = within;
        while (i < tmpfs.CHUNK_DATA and written < buf.len) : (i += 1) {
            chunk.data[i] = buf[written];
            written += 1;
        }
        if (i > chunk.len) {
            chunk.len = i;
        }
    }

    const end: u64 = offset + written;
    if (end > node.size) {
        node.size = end;
    }
    return written;
}
