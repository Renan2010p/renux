// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// Terminal ioctl requests.
//
// This is the Zig counterpart of NetBSD's sys/sys/ttycom.h, reduced to the
// requests the terminal layer answers. The numbers are built with the same
// _IOC encoding FreeBSD uses (sys/ioccom.zig), so they depend on the size of the argument
// structure.

const termios: type = @import("termios.zig");

const ioccom: type = @import("ioccom.zig");
const IOC_OUT: u64 = ioccom.IOC_OUT;
const IOC_IN: u64 = ioccom.IOC_IN;
const ioc = ioccom.ioc;

/// Get terminal attributes (a struct termios).
pub const TIOCGETA: u64 = ioc(IOC_OUT, 't', 19, @sizeOf(termios.Termios));
/// Set terminal attributes (a struct termios).
pub const TIOCSETA: u64 = ioc(IOC_IN, 't', 20, @sizeOf(termios.Termios));
/// Set terminal attributes after draining output (a struct termios).
pub const TIOCSETAW: u64 = ioc(IOC_IN, 't', 21, @sizeOf(termios.Termios));
/// Set terminal attributes, flushing input and draining output.
pub const TIOCSETAF: u64 = ioc(IOC_IN, 't', 22, @sizeOf(termios.Termios));
/// Get the window size (a struct winsize).
pub const TIOCGWINSZ: u64 = ioc(IOC_OUT, 't', 104, @sizeOf(termios.Winsize));
/// Set the window size (a struct winsize).
pub const TIOCSWINSZ: u64 = ioc(IOC_IN, 't', 103, @sizeOf(termios.Winsize));
/// Get the process group of the terminal (an int).
pub const TIOCGPGRP: u64 = ioc(IOC_OUT, 't', 119, @sizeOf(c_int));
/// Set the process group of the terminal (an int).
pub const TIOCSPGRP: u64 = ioc(IOC_IN, 't', 118, @sizeOf(c_int));
/// Get the number of bytes available to read (an int).
pub const FIONREAD: u64 = ioc(IOC_OUT, 'f', 127, @sizeOf(c_int));

/// struct fiodgname_arg (sys/filio.h): the buffer FIODGNAME fills.
pub const FiodgnameArg: type = extern struct {
    len: c_int,
    buf: ?[*]u8,
};

/// Get the device name of a descriptor (what ttyname(3) and devname(3) use).
pub const FIODGNAME: u64 = ioc(IOC_IN, 'f', 120, @sizeOf(FiodgnameArg));
