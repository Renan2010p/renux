// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The Renux Project
//
// tmpfs internal structures.
//
// This is the Zig counterpart of NetBSD's sys/fs/tmpfs/tmpfs.h, reduced to
// what a memory filesystem needs here: a file node (inode), a directory entry,
// a chunk of regular-file contents, and the per-mount record. A node keeps the
// attributes common to every file type plus the type-specific fields a
// directory (parent and entry list) or a regular file (its chunk list) needs.

const vnode: type = @import("../../sys/vnode.zig");

/// Longest file name tmpfs accepts (NetBSD's TMPFS_MAXNAMLEN).
pub const MAXNAMLEN: usize = 255;

/// Bytes of file contents kept in one chunk. Chosen so that a Chunk fits in
/// kmem's largest (one page) size class once its header is accounted for.
pub const CHUNK_DATA: usize = 4064;

/// One chunk of a regular file's contents.
pub const Chunk: type = struct {
    /// Next chunk in file order.
    next: ?*Chunk,
    /// Bytes used in `data`.
    len: usize,
    /// The bytes themselves.
    data: [CHUNK_DATA]u8,
};

/// A directory entry: a name bound to a node.
pub const Dirent: type = struct {
    /// The node the name refers to.
    node: *Node,
    /// The entry's name (owned by the entry).
    name: []u8,
    /// Next entry in the directory.
    next: ?*Dirent,
};

/// A filesystem object (inode).
pub const Node: type = struct {
    /// The vnode that refers to this node, created on first use.
    vnode: ?*vnode.Vnode,
    /// Object type (VREG, VDIR, ...).
    type: vnode.Vtype,
    /// Serial number, unique within the mount.
    id: u64,
    /// Size in bytes (regular files).
    size: u64,
    /// Permission bits.
    mode: u16,
    /// Number of hard links.
    nlink: u32,
    uid: u32,
    gid: u32,
    /// Device number, for VCHR/VBLK nodes.
    rdev: u64,
    atime: i64,
    mtime: i64,
    ctime: i64,

    // Directory fields.
    /// Parent directory (the root points to itself).
    parent: ?*Node,
    /// First directory entry, or null when empty.
    entries: ?*Dirent,

    // Regular-file fields.
    /// First chunk of contents, or null when empty.
    data_head: ?*Chunk,
    /// Last chunk of contents, for appending.
    data_tail: ?*Chunk,
    /// Number of chunks on the list.
    nchunks: usize,
};

/// Per-mount state.
pub const TmpfsMount: type = struct {
    /// The root node.
    root: *Node,
    /// Next inode number to hand out.
    next_id: u64,
};
