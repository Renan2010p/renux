// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Pipes.
//
// The Zig counterpart of FreeBSD's sys/kern/sys_pipe.c: pipe2(2) creates a
// one-way byte channel with a read end and a write end, each an open file.
// The data lives in a one-page ring buffer. Reading an empty pipe waits for a
// writer (or returns end-of-file once every write end is closed); writing a
// full pipe waits for a reader; writing a pipe nobody can read raises SIGPIPE
// and fails with EPIPE, as POSIX requires.
//
// Waiting goes through the generic read/write loops (sys_generic.zig), which
// retry an operation that reports EAGAIN after yielding the CPU.

const sys: type = @import("../sys/syscall.zig");
const errno: type = @import("../sys/errno.zig");
const file: type = @import("../sys/file.zig");
const proc: type = @import("../sys/proc.zig");
const signal: type = @import("../sys/signal.zig");
const stat: type = @import("../sys/stat.zig");
const param: type = @import("../sys/param.zig");
const arch: type = @import("../arch/arch.zig");
const kmem: type = @import("subr_kmem.zig");
const vm_page: type = @import("../vm/vm_page.zig");
const kern_proc: type = @import("kern_proc.zig");
const kern_descrip: type = @import("kern_descrip.zig");
const kern_signal: type = @import("kern_signal.zig");
const kern_time: type = @import("kern_time.zig");

/// Bytes a pipe buffers (one page). POSIX's PIPE_BUF (writes of up to 512
/// bytes are atomic) holds because a write only proceeds when it fits whole
/// or the pipe is empty.
const PIPE_SIZE: usize = param.PAGE_SIZE;
const PIPE_BUF: usize = 512;

/// One pipe, shared by its two open files.
const Pipe: type = struct {
    /// Physical page of the ring buffer.
    page: u64,
    buf: [*]u8,
    head: usize, // next byte to read
    count: usize, // bytes buffered
    readers: u32, // open read ends
    writers: u32, // open write ends
    ino: u64,
    ctime: i64,
};

var next_ino: u64 = 1;

fn pipeOf(f: *file.File) *Pipe {
    return @ptrCast(@alignCast(f.f_data.?));
}

fn pipeRead(f: *file.File, buf: []u8) isize {
    const p: *Pipe = pipeOf(f);
    if (buf.len == 0) return 0;
    if (p.count == 0) {
        // Empty: end-of-file once nobody can write any more, else wait.
        return if (p.writers == 0) 0 else -@as(isize, errno.EAGAIN);
    }
    const n: usize = @min(buf.len, p.count);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        buf[i] = p.buf[(p.head + i) % PIPE_SIZE];
    }
    p.head = (p.head + n) % PIPE_SIZE;
    p.count -= n;
    return @intCast(n);
}

fn pipeWrite(f: *file.File, buf: []const u8) isize {
    const p: *Pipe = pipeOf(f);
    if (p.readers == 0) {
        kern_signal.psignal(kern_proc.current, signal.SIGPIPE);
        return -@as(isize, errno.EPIPE);
    }
    if (buf.len == 0) return 0;
    const space: usize = PIPE_SIZE - p.count;
    // Small writes go in whole (PIPE_BUF atomicity); larger ones in pieces.
    if (space == 0 or (buf.len <= PIPE_BUF and space < buf.len)) {
        return -@as(isize, errno.EAGAIN);
    }
    const n: usize = @min(buf.len, space);
    const tail: usize = (p.head + p.count) % PIPE_SIZE;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p.buf[(tail + i) % PIPE_SIZE] = buf[i];
    }
    p.count += n;
    return @intCast(n);
}

fn pipeStat(f: *file.File, st: *stat.Stat) i32 {
    const p: *Pipe = pipeOf(f);
    st.* = @import("std").mem.zeroes(stat.Stat);
    st.mode = @intCast(stat.S_IFIFO | 0o600);
    st.nlink = 1;
    st.ino = p.ino;
    st.uid = kern_proc.current.euid;
    st.gid = kern_proc.current.egid;
    st.size = @intCast(p.count);
    st.blksize = PIPE_SIZE;
    st.atim.sec = p.ctime;
    st.mtim.sec = p.ctime;
    st.ctim.sec = p.ctime;
    return 0;
}

/// poll(2) readiness of one end.
fn pipePoll(f: *file.File) u16 {
    const p: *Pipe = pipeOf(f);
    var ev: u16 = 0;
    if ((f.f_flag & file.FREAD) != 0) {
        if (p.count > 0) ev |= file.POLLIN;
        if (p.writers == 0) ev |= file.POLLHUP;
    }
    if ((f.f_flag & file.FWRITE) != 0) {
        if (p.readers == 0) {
            ev |= file.POLLERR;
        } else if (PIPE_SIZE - p.count >= PIPE_BUF) {
            ev |= file.POLLOUT;
        }
    }
    return ev;
}

fn pipeClose(f: *file.File) i32 {
    const p: *Pipe = pipeOf(f);
    if ((f.f_flag & file.FREAD) != 0) p.readers -= 1;
    if ((f.f_flag & file.FWRITE) != 0) p.writers -= 1;
    if (p.readers == 0 and p.writers == 0) {
        vm_page.physfree(p.page);
        kmem.free(@ptrCast(p));
    }
    return 0;
}

const pipe_ops: file.FileOps = .{
    .read = pipeRead,
    .write = pipeWrite,
    .stat = pipeStat,
    .close = pipeClose,
    .poll = pipePoll,
};

/// pipe2(2): `pipe2(int fildes[2], int flags)`; fildes[0] reads, fildes[1]
/// writes. O_CLOEXEC marks both close-on-exec; O_NONBLOCK is accepted.
pub fn sysPipe2(args: [sys.MAXARGS]u64) u64 {
    const O_NONBLOCK: u64 = 0x0004;
    const O_CLOEXEC: u64 = 0x00100000;
    if ((args[1] & ~(O_NONBLOCK | O_CLOEXEC)) != 0) return sys.signed(-errno.EINVAL);
    if (args[0] == 0) return sys.signed(-errno.EFAULT);
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return sys.signed(-errno.ENOMEM);

    const p: *Pipe = kmem.zallocAs(Pipe) orelse return sys.signed(-errno.ENFILE);
    const page: u64 = vm_page.physalloc() orelse {
        kmem.free(@ptrCast(p));
        return sys.signed(-errno.ENFILE);
    };
    p.* = .{
        .page = page,
        .buf = @ptrFromInt(page + hhdm),
        .head = 0,
        .count = 0,
        .readers = 1,
        .writers = 1,
        .ino = next_ino,
        .ctime = @intCast(kern_time.now()),
    };
    next_ino += 1;

    const rf: *file.File = kern_descrip.newFile(file.DTYPE_PIPE, file.FREAD, p, &pipe_ops) orelse {
        vm_page.physfree(page);
        kmem.free(@ptrCast(p));
        return sys.signed(-errno.ENFILE);
    };
    const wf: *file.File = kern_descrip.newFile(file.DTYPE_PIPE, file.FWRITE, p, &pipe_ops) orelse {
        p.writers = 0; // closing rf then frees the pipe
        _ = kern_descrip.closeFile(rf);
        return sys.signed(-errno.ENFILE);
    };

    const cur: *proc.Proc = kern_proc.current;
    const rfd: usize = kern_descrip.fdalloc(cur, 0) orelse {
        _ = kern_descrip.closeFile(rf);
        _ = kern_descrip.closeFile(wf);
        return sys.signed(-errno.EMFILE);
    };
    kern_descrip.fdAffix(cur, rfd, rf);
    const wfd: usize = kern_descrip.fdalloc(cur, 0) orelse {
        _ = kern_descrip.fd_close(cur, rfd);
        _ = kern_descrip.closeFile(wf);
        return sys.signed(-errno.EMFILE);
    };
    kern_descrip.fdAffix(cur, wfd, wf);
    const cloexec: bool = (args[1] & O_CLOEXEC) != 0;
    kern_descrip.fdSetCloexec(cur, rfd, cloexec);
    kern_descrip.fdSetCloexec(cur, wfd, cloexec);

    const fildes: [*]align(1) i32 = @ptrFromInt(args[0]);
    fildes[0] = @intCast(rfd);
    fildes[1] = @intCast(wfd);
    return 0;
}
