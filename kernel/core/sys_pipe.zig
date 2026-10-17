// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Pipes.
//
// The Zig counterpart of FreeBSD's sys/kern/sys_pipe.c: pipe2(2) creates a
// one-way byte channel with a read end and a write end, each an open file.
// The data lives in a ring buffer sized as FreeBSD sizes it: PIPE_SIZE
// (16 KiB) to begin with, one page when pipes already hold half of
// maxpipekva, and BIG_PIPE_SIZE (64 KiB) once a large write finds the pipe
// empty. Reading an empty pipe waits for a
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
const kern_sched: type = @import("kern_sched.zig");
const subr_param: type = @import("subr_param.zig");

/// Buffer sizes (FreeBSD's sys/pipe.h): the usual one, the one a pipe grows
/// to for large writes, and the one it falls back to when memory for pipes
/// runs short.
const PIPE_SIZE: usize = 16384;
const BIG_PIPE_SIZE: usize = 64 * 1024;
const SMALL_PIPE_SIZE: usize = param.PAGE_SIZE;
/// POSIX's PIPE_BUF: writes of up to 512 bytes are atomic, because a write
/// only proceeds when it fits whole or the pipe is empty.
const PIPE_BUF: usize = 512;

/// Bytes of buffer all pipes hold together (FreeBSD's amountpipekva); the
/// ceiling is subr_param.maxpipekva.
var amountpipekva: usize = 0;

/// One pipe, shared by its two open files.
const Pipe: type = struct {
    /// Physical address of the ring buffer, and its size.
    page: u64,
    size: usize,
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
        buf[i] = p.buf[(p.head + i) % p.size];
    }
    p.head = (p.head + n) % p.size;
    p.count -= n;
    kern_sched.ioWakeup(); // a writer may be waiting for room
    return @intCast(n);
}

fn pipeWrite(f: *file.File, buf: []const u8) isize {
    const p: *Pipe = pipeOf(f);
    if (p.readers == 0) {
        kern_signal.psignal(kern_proc.current, signal.SIGPIPE);
        return -@as(isize, errno.EPIPE);
    }
    if (buf.len == 0) return 0;
    // A large write into an empty pipe gets the big buffer, if memory for
    // pipes allows (FreeBSD's pipe_write).
    if (buf.len > PIPE_SIZE and p.size <= PIPE_SIZE and p.count == 0 and amountpipekva < subr_param.maxpipekva / 2) {
        _ = pipespace(p, BIG_PIPE_SIZE);
    }
    const space: usize = p.size - p.count;
    // Small writes go in whole (PIPE_BUF atomicity); larger ones in pieces.
    if (space == 0 or (buf.len <= PIPE_BUF and space < buf.len)) {
        return -@as(isize, errno.EAGAIN);
    }
    const n: usize = @min(buf.len, space);
    const tail: usize = (p.head + p.count) % p.size;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        p.buf[(tail + i) % p.size] = buf[i];
    }
    p.count += n;
    kern_sched.ioWakeup(); // a reader may be waiting for data
    return @intCast(n);
}

/// Give pipe `p`, which must be empty, a buffer of `size` bytes in place
/// of the one it has (FreeBSD's pipespace). False, leaving the old buffer,
/// when memory for pipes or physical memory runs out.
fn pipespace(p: *Pipe, size: usize) bool {
    const hhdm: u64 = arch.boot.hhdmOffset() orelse return false;
    if (amountpipekva + size > subr_param.maxpipekva) return false;
    const pa: vm_page.PAddr = vm_page.physallocContig(size / param.PAGE_SIZE) orelse return false;
    freeBuffer(p);
    p.page = pa.int();
    p.size = size;
    p.buf = @ptrFromInt(pa.int() + hhdm);
    p.head = 0;
    amountpipekva += size;
    return true;
}

fn freeBuffer(p: *Pipe) void {
    if (p.size == 0) return;
    vm_page.physfreeContig(vm_page.PAddr.fromInt(p.page), p.size / param.PAGE_SIZE);
    amountpipekva -= p.size;
    p.size = 0;
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
    st.blksize = @intCast(p.size);
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
        } else if (p.size - p.count >= PIPE_BUF) {
            ev |= file.POLLOUT;
        }
    }
    return ev;
}

fn pipeClose(f: *file.File) i32 {
    const p: *Pipe = pipeOf(f);
    if ((f.f_flag & file.FREAD) != 0) p.readers -= 1;
    if ((f.f_flag & file.FWRITE) != 0) p.writers -= 1;
    // The other end sees end-of-file or EPIPE now.
    kern_sched.ioWakeup();
    if (p.readers == 0 and p.writers == 0) {
        freeBuffer(p);
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
/// writes. O_CLOEXEC marks both close-on-exec; O_NONBLOCK makes both ends
/// non-blocking (FNONBLOCK).
pub fn sysPipe2(args: [sys.MAXARGS]u64) u64 {
    const O_NONBLOCK: u64 = 0x0004;
    const O_CLOEXEC: u64 = 0x00100000;
    if ((args[1] & ~(O_NONBLOCK | O_CLOEXEC)) != 0) return sys.signed(-errno.EINVAL);
    if (args[0] == 0) return sys.signed(-errno.EFAULT);

    const p: *Pipe = kmem.zallocAs(Pipe) orelse return sys.signed(-errno.ENFILE);
    p.* = .{
        .page = 0,
        .size = 0,
        .buf = undefined,
        .head = 0,
        .count = 0,
        .readers = 1,
        .writers = 1,
        .ino = next_ino,
        .ctime = @intCast(kern_time.now()),
    };
    next_ino += 1;
    // The usual buffer, or a single page once pipes hold half of what they
    // may (FreeBSD's pipe_create); failing both, no pipe.
    const size: usize = if (amountpipekva > subr_param.maxpipekva / 2) SMALL_PIPE_SIZE else PIPE_SIZE;
    if (!pipespace(p, size) and !pipespace(p, SMALL_PIPE_SIZE)) {
        kmem.free(@ptrCast(p));
        return sys.signed(-errno.ENFILE);
    }

    const nonblock: i32 = if ((args[1] & O_NONBLOCK) != 0) file.FNONBLOCK else 0;
    const rf: *file.File = kern_descrip.newFile(file.DTYPE_PIPE, file.FREAD | nonblock, p, &pipe_ops) orelse {
        freeBuffer(p);
        kmem.free(@ptrCast(p));
        return sys.signed(-errno.ENFILE);
    };
    const wf: *file.File = kern_descrip.newFile(file.DTYPE_PIPE, file.FWRITE | nonblock, p, &pipe_ops) orelse {
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
