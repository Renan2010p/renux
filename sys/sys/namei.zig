// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 The ZenBSD Project
//
// Pathname lookup parameters.
//
// This is the Zig counterpart of NetBSD's sys/sys/namei.h, reduced to the
// component name that travels down to VOP_LOOKUP/VOP_CREATE and the operation
// and flag bits that steer a lookup. The full struct nameidata is not modelled
// yet: namei() keeps its traversal state locally (see kern/vfs_lookup.zig).

/// Namei operations (the cn_nameiop field).
pub const LOOKUP: u32 = 0; // perform name lookup only
pub const CREATE: u32 = 1; // set up for file creation
pub const DELETE: u32 = 2; // set up for file deletion
pub const RENAME: u32 = 3; // set up for file renaming
pub const OPMASK: u32 = 3; // mask for the operation

/// Namei flag bits, stored in Componentname.flags (a subset of NetBSD's).
pub const FOLLOW: u32 = 0x00000040; // follow symbolic links
pub const NOFOLLOW: u32 = 0x00000000; // do not follow symbolic links
pub const ISDOT: u32 = 0x00000001; // current component is "."
pub const ISDOTDOT: u32 = 0x00000002; // current component is ".."
pub const ISLASTCN: u32 = 0x00000004; // this is the last component
pub const REQUIREDIR: u32 = 0x00000008; // the result must be a directory
pub const WILLBEDIR: u32 = 0x00000010; // a created file will be a directory

/// One pathname component, passed to VOP_LOOKUP/VOP_CREATE (NetBSD's struct
/// componentname).
pub const Componentname: type = struct {
    /// Pointer to the component name (not NUL-terminated).
    nameptr: [*]const u8,
    /// Length of the component name.
    namelen: usize,
    /// One of LOOKUP, CREATE, DELETE or RENAME.
    nameiop: u32,
    /// Flag bits from the N* set above.
    flags: u32,
};
