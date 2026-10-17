// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// xHCI USB host controller.
//
// The Zig counterpart of FreeBSD's sys/dev/usb/controller/xhci.c and
// xhci_pci.c, reduced to what a keyboard on a root port needs:
//
//   - PCI attach: take the controller from the firmware (the USB Legacy
//     Support capability, which also ends the BIOS's PS/2 emulation), and
//     on Intel PCHs route the USB 2.0 ports from the EHCI controllers to the
//     xHCI (XUSB2PR), as FreeBSD's xhci_pci_port_route() does;
//   - controller bring-up: reset, scratchpad buffers, the device context
//     base address array, a command ring and one event ring;
//   - root ports: reset, Enable Slot and Address Device, then hand the
//     device to the USB layer (usb_device.zig) to read its descriptors;
//   - transfers: synchronous control transfers on the default endpoint, an
//     asynchronous one for class requests at run time (keyboard LEDs), and
//     one interrupt IN pipe per device.
//
// There are no interrupts yet: the event ring is polled, during bring-up
// while a command or transfer is waited for, and afterwards from the clock
// tick (100 Hz, enough for a keyboard's 8 or 10 ms polling interval). Port
// changes found by the tick attach and detach devices, so a keyboard may be
// plugged in after boot. Hubs are not supported: a device must sit on a
// root port.

const arch: type = @import("../../../arch/arch.zig");
const bus: type = @import("../../../sys/bus.zig");
const param: type = @import("../../../sys/param.zig");
const sysinit: type = @import("../../../sys/sysinit.zig");
const prf: type = @import("../../../core/subr_prf.zig");
const subr_bus: type = @import("../../../core/subr_bus.zig");
const vm_page: type = @import("../../../vm/vm_page.zig");
const pci: type = @import("../../pci/pci.zig");
const usb: type = @import("../usb.zig");
const usb_device: type = @import("../usb_device.zig");
const xr: type = @import("xhcireg.zig");

/// PCI class of a USB controller, and the xHCI programming interface.
const PCIC_SERIALBUS: u8 = 0x0c;
const PCIS_SERIALBUS_USB: u8 = 0x03;
const PCIP_SERIALBUS_USB_XHCI: u8 = 0x30;

/// Device slots enabled (the controller may offer more).
const MAXSLOTS: u32 = 16;
/// TRBs per ring: one page. A transfer ring's last TRB links back to its
/// first.
const NTRBS: u32 = @intCast(param.PAGE_SIZE / @sizeOf(xr.Trb));
const MAXPORTS: usize = 256;
const MAXUNITS: usize = 2;

/// Layout of a device's DMA buffer page.
const BUF_CTRL: u64 = 0; // control transfer data (synchronous)
const BUF_CTRL_SIZE: u64 = 2048;
const BUF_INTR: u64 = 2048; // interrupt IN data
const BUF_INTR_SIZE: u64 = 1024;
const BUF_ASYNC: u64 = 3072; // asynchronous control transfer data
const BUF_ASYNC_SIZE: u64 = 1024;

/// A physically contiguous page: its bus address and where the kernel sees it.
const Dma: type = struct {
    pa: u64 = 0,
    va: u64 = 0,

    fn ptr(self: Dma, comptime T: type) T {
        return @ptrFromInt(self.va);
    }
};

/// A producer ring: the command ring or a transfer ring.
const Ring: type = struct {
    dma: Dma = .{},
    idx: u32 = 0,
    cycle: u32 = 1,

    fn trbs(self: *const Ring) [*]volatile xr.Trb {
        return self.dma.ptr([*]volatile xr.Trb);
    }

    fn init(self: *Ring, sc: *Softc) bool {
        self.dma = sc.dmaAlloc() orelse return false;
        self.idx = 0;
        self.cycle = 1;
        const link: *volatile xr.Trb = &self.trbs()[NTRBS - 1];
        link.param = self.dma.pa;
        link.status = 0;
        link.control = xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_LINK) | xr.XHCI_TRB_TC;
        return true;
    }

    /// Append one TRB, handing it to the controller with the current cycle
    /// bit; returns its bus address. At the end of the ring the link TRB is
    /// given to the controller too and the cycle flips.
    fn push(self: *Ring, prm: u64, status: u32, ctl: u32) u64 {
        const t: *volatile xr.Trb = &self.trbs()[self.idx];
        t.param = prm;
        t.status = status;
        t.control = ctl | self.cycle;
        const pa: u64 = self.dma.pa + @as(u64, self.idx) * @sizeOf(xr.Trb);
        self.idx += 1;
        if (self.idx == NTRBS - 1) {
            const link: *volatile xr.Trb = &self.trbs()[NTRBS - 1];
            link.control = xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_LINK) | xr.XHCI_TRB_TC | self.cycle;
            self.cycle ^= 1;
            self.idx = 0;
        }
        return pa;
    }

    /// The enqueue position, as a TR dequeue pointer with its cycle state.
    fn dequeuePointer(self: *const Ring) u64 {
        return (self.dma.pa + @as(u64, self.idx) * @sizeOf(xr.Trb)) | self.cycle;
    }
};

/// What a class driver gets from an interrupt IN pipe.
pub const IntrCallback: type = *const fn (ctx: ?*anyopaque, data: []const u8) void;
/// Called when the device goes away.
pub const DetachCallback: type = *const fn (ctx: ?*anyopaque) void;

const Pipe: type = struct {
    active: bool = false,
    halted: bool = false,
    dci: u32 = 0,
    mps: u32 = 0,
    ring: Ring = .{},
    cb: ?IntrCallback = null,
    ctx: ?*anyopaque = null,
};

/// A USB device on a root port (the part of FreeBSD's usb_device the
/// controller keeps).
pub const Device: type = struct {
    sc: *Softc = undefined,
    active: bool = false,
    slot: u32 = 0,
    port: u32 = 0,
    /// XHCI_SPEED_*.
    speed: u32 = 0,
    out_ctx: Dma = .{},
    in_ctx: Dma = .{},
    buf: Dma = .{},
    ep0: Ring = .{},
    mps0: u32 = 8,

    // The default endpoint's transfer in flight.
    ep0_busy: bool = false,
    ep0_done: bool = false,
    ep0_cc: u32 = 0,
    ep0_remain: u32 = 0,
    ep0_data_pa: u64 = 0,
    ep0_status_pa: u64 = 0,

    intr: Pipe = .{},

    /// The class driver that claimed the device.
    driver_ctx: ?*anyopaque = null,
    driver_detach: ?DetachCallback = null,

    /// "usbus<unit>", the device's parent name.
    pub fn busName(self: *const Device) []const u8 {
        return self.sc.busname[0..self.sc.busname_len];
    }

    pub fn busUnit(self: *const Device) u32 {
        return self.sc.unit;
    }

    /// The USB address the controller gave the device (slot context).
    pub fn address(self: *const Device) u32 {
        return self.sc.ctx(self.out_ctx, 0)[3] & 0xff;
    }
};

pub const Softc: type = struct {
    unit: u32 = 0,
    pcidev: *pci.PciDev = undefined,
    /// Virtual addresses of the register sets.
    cap: u64 = 0,
    op: u64 = 0,
    rt: u64 = 0,
    db: u64 = 0,
    ctx_size: u64 = 32,
    ac64: bool = false,
    nslots: u32 = 0,
    nports: u32 = 0,
    dcbaa: Dma = .{},
    cmd: Ring = .{},
    ev: Dma = .{},
    erst: Dma = .{},
    ev_idx: u32 = 0,
    ev_cycle: u32 = 1,

    // The command in flight.
    cmd_pa: u64 = 0,
    cmd_done: bool = false,
    cmd_cc: u32 = 0,
    cmd_slot: u32 = 0,

    /// Major USB revision of each port (2 or 3), from the Supported Protocol
    /// capabilities.
    port_major: [MAXPORTS]u8 = @splat(0),
    port_slot: [MAXPORTS]u8 = @splat(0),
    /// A device on the port failed to enumerate; retried after it is
    /// unplugged.
    port_failed: [MAXPORTS]bool = @splat(false),
    port_event: bool = false,
    devices: [MAXSLOTS + 1]Device = @splat(.{}),

    busname: [16]u8 = undefined,
    busname_len: usize = 0,

    fn rd4(base: u64, off: u64) u32 {
        return bus.bus_space_read_4(bus.BUS_SPACE_MEM, base, off);
    }

    fn wr4(base: u64, off: u64, v: u32) void {
        bus.bus_space_write_4(bus.BUS_SPACE_MEM, base, off, v);
    }

    fn opRead(self: *const Softc, off: u64) u32 {
        return rd4(self.op, off);
    }

    fn opWrite(self: *const Softc, off: u64, v: u32) void {
        wr4(self.op, off, v);
    }

    fn opWrite64(self: *const Softc, lo: u64, v: u64) void {
        wr4(self.op, lo, @truncate(v));
        wr4(self.op, lo + 4, @truncate(v >> 32));
    }

    fn doorbell(self: *const Softc, slot: u32, target: u32) void {
        wr4(self.db, 4 * @as(u64, slot), target);
    }

    /// A zeroed page the controller can reach.
    fn dmaAlloc(self: *const Softc) ?Dma {
        const hhdm: u64 = arch.boot.hhdmOffset() orelse return null;
        const pa: vm_page.PAddr = vm_page.physalloc() orelse return null;
        if (!self.ac64 and pa.int() >= (1 << 32)) {
            vm_page.physfree(pa);
            return null;
        }
        return .{ .pa = pa.int(), .va = pa.int() + hhdm };
    }

    fn dmaFree(dma: *Dma) void {
        if (dma.pa != 0) vm_page.physfree(vm_page.PAddr.fromInt(dma.pa));
        dma.* = .{};
    }

    /// Context `i` of the context page `page` (0 is the input control
    /// context of an input context, or the slot context of a device
    /// context).
    fn ctx(self: *const Softc, page: Dma, i: u64) [*]volatile u32 {
        return @ptrFromInt(page.va + i * self.ctx_size);
    }

    fn clearInputContext(dev: *Device) void {
        @memset(dev.in_ctx.ptr([*]u8)[0..param.PAGE_SIZE], 0);
    }

    // -- events -----------------------------------------------------------------

    /// Consume every event the controller has posted.
    fn processEvents(self: *Softc) void {
        const ring: [*]volatile xr.Trb = self.ev.ptr([*]volatile xr.Trb);
        var n: u32 = 0;
        while (true) {
            const t: *volatile xr.Trb = &ring[self.ev_idx];
            const ctl: u32 = t.control;
            if ((ctl & xr.XHCI_TRB_CYCLE) != self.ev_cycle) break;
            const prm: u64 = t.param;
            const status: u32 = t.status;
            self.ev_idx += 1;
            if (self.ev_idx == NTRBS) {
                self.ev_idx = 0;
                self.ev_cycle ^= 1;
            }
            n += 1;
            self.handleEvent(prm, status, ctl);
        }
        if (n > 0) {
            const erdp: u64 = self.ev.pa + @as(u64, self.ev_idx) * @sizeOf(xr.Trb);
            wr4(self.rt, xr.XHCI_ERDP_LO(0), @as(u32, @truncate(erdp)) | xr.XHCI_ERDP_BUSY);
            wr4(self.rt, xr.XHCI_ERDP_HI(0), @truncate(erdp >> 32));
        }
    }

    fn handleEvent(self: *Softc, prm: u64, status: u32, ctl: u32) void {
        const cc: u32 = xr.XHCI_TRB_ERROR_GET(status);
        switch (xr.XHCI_TRB_TYPE_GET(ctl)) {
            xr.XHCI_TRB_EVENT_CMD_COMPLETE => {
                if (prm != self.cmd_pa) return;
                self.cmd_cc = cc;
                self.cmd_slot = xr.XHCI_TRB_SLOT_GET(ctl);
                @as(*volatile bool, &self.cmd_done).* = true;
            },
            xr.XHCI_TRB_EVENT_TRANSFER => {
                const slot: u32 = xr.XHCI_TRB_SLOT_GET(ctl);
                if (slot == 0 or slot > MAXSLOTS) return;
                const dev: *Device = &self.devices[slot];
                if (!dev.active) return;
                const dci: u32 = xr.XHCI_TRB_EP_GET(ctl);
                if (dci == 1) {
                    ep0Event(dev, prm, cc, xr.XHCI_TRB_REMAIN_GET(status));
                } else if (dev.intr.active and dci == dev.intr.dci) {
                    intrEvent(dev, cc, xr.XHCI_TRB_REMAIN_GET(status));
                }
            },
            xr.XHCI_TRB_EVENT_PORT_STS_CHANGE => self.port_event = true,
            else => {},
        }
    }

    /// Poll the event ring until `flag` is set, for at most `ms` ms.
    fn waitFor(self: *Softc, flag: *bool, ms: u32) bool {
        var i: u32 = 0;
        while (i < ms * 10) : (i += 1) {
            self.processEvents();
            if (@as(*volatile bool, flag).*) return true;
            arch.clock.DELAY(100);
        }
        self.processEvents();
        return @as(*volatile bool, flag).*;
    }

    // -- commands ---------------------------------------------------------------

    const CmdResult: type = struct { cc: u32, slot: u32 };

    /// Post a command and wait for its completion event.
    fn command(self: *Softc, prm: u64, ctl: u32) ?CmdResult {
        self.cmd_done = false;
        self.cmd_pa = self.cmd.push(prm, 0, ctl);
        self.doorbell(0, 0);
        if (!self.waitFor(&self.cmd_done, 2000)) return null;
        return .{ .cc = self.cmd_cc, .slot = self.cmd_slot };
    }

    fn commandOk(self: *Softc, prm: u64, ctl: u32) bool {
        const r: CmdResult = self.command(prm, ctl) orelse return false;
        return r.cc == xr.XHCI_TRB_ERROR_SUCCESS;
    }

    /// Restart a halted endpoint: Reset Endpoint, then move its dequeue
    /// pointer past the transfer that failed.
    fn recoverEndpoint(self: *Softc, dev: *Device, dci: u32, ring: *const Ring) void {
        const target: u32 = xr.XHCI_TRB_SLOT_SET(dev.slot) | (dci << 16);
        _ = self.command(0, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_RESET_EP) | target);
        _ = self.command(ring.dequeuePointer(), xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_SET_TR_DEQUEUE) | target);
    }

    // -- bring-up ---------------------------------------------------------------

    /// Wait until `(opRead(off) & mask) == want`, for at most `ms` ms.
    fn waitReg(self: *const Softc, off: u64, mask: u32, want: u32, ms: u32) bool {
        var i: u32 = 0;
        while (i < ms * 10) : (i += 1) {
            if ((self.opRead(off) & mask) == want) return true;
            arch.clock.DELAY(100);
        }
        return (self.opRead(off) & mask) == want;
    }

    /// Walk the extended capabilities: take ownership from the BIOS and note
    /// which ports are USB 2 and which USB 3.
    fn extendedCaps(self: *Softc, hcc1: u32) void {
        var off: u64 = @as(u64, xr.HCC1_XECP(hcc1)) * 4;
        var guard: u32 = 0;
        while (off != 0 and guard < 64) : (guard += 1) {
            const v: u32 = rd4(self.cap, off);
            switch (xr.XHCI_XECP_ID(v)) {
                xr.XHCI_ID_USB_LEGACY => self.biosHandoff(off),
                xr.XHCI_ID_PROTOCOLS => {
                    const major: u8 = @truncate(v >> 24);
                    const w2: u32 = rd4(self.cap, off + 8);
                    const first: u32 = w2 & 0xff;
                    const count: u32 = (w2 >> 8) & 0xff;
                    var p: u32 = first;
                    while (p < first + count and p < MAXPORTS) : (p += 1) self.port_major[p] = major;
                },
                else => {},
            }
            const next: u32 = xr.XHCI_XECP_NEXT(v);
            if (next == 0) break;
            off += @as(u64, next) * 4;
        }
    }

    /// The BIOS/OS handoff (xHCI 1.2, 4.22.1), and the firmware's SMIs off.
    fn biosHandoff(self: *Softc, off: u64) void {
        var v: u32 = rd4(self.cap, off);
        if ((v & xr.XHCI_XECP_BIOS_SEM) != 0) {
            wr4(self.cap, off, v | xr.XHCI_XECP_OS_SEM);
            var i: u32 = 0;
            while (i < 10_000) : (i += 1) { // 1 s
                v = rd4(self.cap, off);
                if ((v & xr.XHCI_XECP_BIOS_SEM) == 0) break;
                arch.clock.DELAY(100);
            }
            if ((v & xr.XHCI_XECP_BIOS_SEM) != 0) {
                prf.printf("xhci%u: BIOS did not release the controller, taking it\n", .{self.unit});
                wr4(self.cap, off, (v & ~xr.XHCI_XECP_BIOS_SEM) | xr.XHCI_XECP_OS_SEM);
            }
        } else {
            wr4(self.cap, off, v | xr.XHCI_XECP_OS_SEM);
        }
        const ctl: u32 = rd4(self.cap, off + 4);
        wr4(self.cap, off + 4, (ctl & ~xr.XHCI_XECP_LEGCTLSTS_ENABLES) | xr.XHCI_XECP_LEGCTLSTS_EVENTS);
    }

    fn halt(self: *Softc) bool {
        self.opWrite(xr.XHCI_USBCMD, self.opRead(xr.XHCI_USBCMD) & ~(xr.XHCI_CMD_RS | xr.XHCI_CMD_INTE));
        return self.waitReg(xr.XHCI_USBSTS, xr.XHCI_STS_HCH, xr.XHCI_STS_HCH, 100);
    }

    fn reset(self: *Softc) bool {
        if (!self.waitReg(xr.XHCI_USBSTS, xr.XHCI_STS_CNR, 0, 1000)) return false;
        if (!self.halt()) return false;
        self.opWrite(xr.XHCI_USBCMD, xr.XHCI_CMD_HCRST);
        // Intel controllers must not be touched for a while after a reset.
        arch.clock.DELAY(1000);
        if (!self.waitReg(xr.XHCI_USBCMD, xr.XHCI_CMD_HCRST, 0, 1000)) return false;
        return self.waitReg(xr.XHCI_USBSTS, xr.XHCI_STS_CNR, 0, 1000);
    }

    /// Scratchpad buffers the controller asked for: an array of page
    /// pointers in DCBAA entry 0.
    fn scratchpads(self: *Softc, n: u32) bool {
        if (n == 0) return true;
        if (n > param.PAGE_SIZE / 8) return false;
        const array: Dma = self.dmaAlloc() orelse return false;
        const entries: [*]volatile u64 = array.ptr([*]volatile u64);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const page: Dma = self.dmaAlloc() orelse return false;
            entries[i] = page.pa;
        }
        self.dcbaa.ptr([*]volatile u64)[0] = array.pa;
        return true;
    }

    fn start(self: *Softc) bool {
        const hcs1: u32 = rd4(self.cap, xr.XHCI_HCSPARAMS1);
        const hcs2: u32 = rd4(self.cap, xr.XHCI_HCSPARAMS2);
        const hcc1: u32 = rd4(self.cap, xr.XHCI_HCCPARAMS1);
        self.ac64 = (hcc1 & xr.HCC1_AC64) != 0;
        self.ctx_size = if ((hcc1 & xr.HCC1_CSZ) != 0) 64 else 32;
        self.nslots = @min(xr.HCS1_DEVSLOT_MAX(hcs1), MAXSLOTS);
        self.nports = @min(xr.HCS1_N_PORTS(hcs1), MAXPORTS - 1);

        self.extendedCaps(hcc1);
        if (!self.reset()) {
            prf.printf("xhci%u: controller reset failed\n", .{self.unit});
            return false;
        }
        if ((self.opRead(xr.XHCI_PAGESIZE) & 1) == 0) {
            prf.printf("xhci%u: no 4 KiB page support\n", .{self.unit});
            return false;
        }

        self.dcbaa = self.dmaAlloc() orelse return false;
        if (!self.scratchpads(xr.HCS2_SPB_MAX(hcs2))) return false;
        if (!self.cmd.init(self)) return false;
        self.ev = self.dmaAlloc() orelse return false;
        self.erst = self.dmaAlloc() orelse return false;
        const seg: *volatile xr.ErstEntry = self.erst.ptr(*volatile xr.ErstEntry);
        seg.base = self.ev.pa;
        seg.size = NTRBS;
        seg.reserved = 0;
        self.ev_idx = 0;
        self.ev_cycle = 1;

        self.opWrite(xr.XHCI_CONFIG, self.nslots);
        self.opWrite64(xr.XHCI_DCBAAP_LO, self.dcbaa.pa);
        self.opWrite64(xr.XHCI_CRCR_LO, self.cmd.dma.pa | xr.XHCI_CRCR_RCS);

        // Interrupter 0, polled: the event ring segment table is written
        // last, which hands the ring to the controller.
        wr4(self.rt, xr.XHCI_IMAN(0), xr.XHCI_IMAN_INTR_PEND);
        wr4(self.rt, xr.XHCI_ERSTSZ(0), 1);
        wr4(self.rt, xr.XHCI_ERDP_LO(0), @truncate(self.ev.pa));
        wr4(self.rt, xr.XHCI_ERDP_HI(0), @truncate(self.ev.pa >> 32));
        wr4(self.rt, xr.XHCI_ERSTBA_LO(0), @truncate(self.erst.pa));
        wr4(self.rt, xr.XHCI_ERSTBA_HI(0), @truncate(self.erst.pa >> 32));

        self.opWrite(xr.XHCI_USBCMD, xr.XHCI_CMD_RS);
        if (!self.waitReg(xr.XHCI_USBSTS, xr.XHCI_STS_HCH, 0, 100)) {
            prf.printf("xhci%u: controller did not start\n", .{self.unit});
            return false;
        }

        // Power the ports where software controls it.
        if ((hcc1 & xr.HCC1_PPC) != 0) {
            var p: u32 = 1;
            while (p <= self.nports) : (p += 1) {
                const ps: u32 = self.opRead(xr.XHCI_PORTSC(p));
                if ((ps & xr.XHCI_PS_PP) == 0) self.opWrite(xr.XHCI_PORTSC(p), (ps & xr.XHCI_PS_PRESERVE) | xr.XHCI_PS_PP);
            }
            arch.clock.DELAY(20_000);
        }
        return true;
    }

    // -- ports ------------------------------------------------------------------

    /// Reset root port `port` and report whether it came up enabled.
    fn resetPort(self: *Softc, port: u32) bool {
        const reg: u64 = xr.XHCI_PORTSC(port);
        var ps: u32 = self.opRead(reg);
        self.opWrite(reg, (ps & xr.XHCI_PS_PRESERVE) | xr.XHCI_PS_PR);
        var i: u32 = 0;
        while (i < 500) : (i += 1) {
            ps = self.opRead(reg);
            if ((ps & xr.XHCI_PS_PRC) != 0 and (ps & xr.XHCI_PS_PR) == 0) break;
            arch.clock.DELAY(1000);
        }
        self.opWrite(reg, (ps & xr.XHCI_PS_PRESERVE) | xr.XHCI_PS_PRC);
        arch.clock.DELAY(10_000); // reset recovery (TRSTRCY)
        return (self.opRead(reg) & xr.XHCI_PS_PED) != 0;
    }

    /// Look at every root port: attach what was plugged in, detach what was
    /// pulled out.
    fn scanPorts(self: *Softc) void {
        var p: u32 = 1;
        while (p <= self.nports) : (p += 1) {
            const reg: u64 = xr.XHCI_PORTSC(p);
            const ps: u32 = self.opRead(reg);
            if ((ps & xr.XHCI_PS_CHANGES) != 0) {
                self.opWrite(reg, (ps & xr.XHCI_PS_PRESERVE) | (ps & xr.XHCI_PS_CHANGES));
            }
            const connected: bool = (ps & xr.XHCI_PS_CCS) != 0;
            if (!connected) {
                self.port_failed[p] = false;
                if (self.port_slot[p] != 0) self.detachDevice(&self.devices[self.port_slot[p]]);
                continue;
            }
            if (self.port_slot[p] != 0 or self.port_failed[p]) continue;
            if (!self.attachPort(p)) self.port_failed[p] = true;
        }
    }

    fn attachPort(self: *Softc, port: u32) bool {
        const usb3: bool = self.port_major[port] == 3;
        const ps: u32 = self.opRead(xr.XHCI_PORTSC(port));
        if (!usb3 or (ps & xr.XHCI_PS_PED) == 0) {
            if (!self.resetPort(port)) return false;
        }
        const speed: u32 = xr.XHCI_PS_SPEED(self.opRead(xr.XHCI_PORTSC(port)));
        const dev: *Device = self.addressDevice(port, speed) orelse return false;
        if (!usb_device.enumerate(dev)) {
            self.detachDevice(dev);
            return false;
        }
        return true;
    }

    // -- devices ----------------------------------------------------------------

    /// Enable a slot for the device on `port` and give it an address.
    fn addressDevice(self: *Softc, port: u32, speed: u32) ?*Device {
        const r: CmdResult = self.command(0, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_ENABLE_SLOT)) orelse return null;
        if (r.cc != xr.XHCI_TRB_ERROR_SUCCESS or r.slot == 0 or r.slot > self.nslots) return null;
        const dev: *Device = &self.devices[r.slot];
        dev.* = .{ .sc = self, .slot = r.slot, .port = port, .speed = speed, .active = true };
        self.port_slot[port] = @intCast(r.slot);

        dev.out_ctx = self.dmaAlloc() orelse return self.failDevice(dev);
        dev.in_ctx = self.dmaAlloc() orelse return self.failDevice(dev);
        dev.buf = self.dmaAlloc() orelse return self.failDevice(dev);
        if (!dev.ep0.init(self)) return self.failDevice(dev);
        self.dcbaa.ptr([*]volatile u64)[r.slot] = dev.out_ctx.pa;

        // A full-speed device's real packet size is read from the first
        // eight bytes of its descriptor, which any size can carry.
        dev.mps0 = switch (speed) {
            xr.XHCI_SPEED_HIGH => 64,
            xr.XHCI_SPEED_SUPER => 512,
            else => 8,
        };
        clearInputContext(dev);
        self.ctx(dev.in_ctx, 0)[xr.XHCI_INCTX_ADD] = 0x3; // slot and EP0
        const slot: [*]volatile u32 = self.ctx(dev.in_ctx, 1);
        slot[0] = xr.XHCI_SCTX_0_SPEED(speed) | xr.XHCI_SCTX_0_CTX_NUM(1);
        slot[1] = xr.XHCI_SCTX_1_RH_PORT(port);
        const ep0: [*]volatile u32 = self.ctx(dev.in_ctx, 2);
        ep0[1] = xr.XHCI_EPCTX_1_CERR(3) | xr.XHCI_EPCTX_1_EPTYPE(xr.XHCI_EPTYPE_CTRL) | xr.XHCI_EPCTX_1_MAXP(dev.mps0);
        const deq: u64 = dev.ep0.dma.pa | xr.XHCI_EPCTX_2_DCS;
        ep0[2] = @truncate(deq);
        ep0[3] = @truncate(deq >> 32);
        ep0[4] = xr.XHCI_EPCTX_4_AVG_TRB_LEN(8);

        if (!self.commandOk(dev.in_ctx.pa, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_ADDRESS_DEVICE) | xr.XHCI_TRB_SLOT_SET(dev.slot))) {
            return self.failDevice(dev);
        }
        arch.clock.DELAY(10_000); // SET_ADDRESS recovery
        return dev;
    }

    fn failDevice(self: *Softc, dev: *Device) ?*Device {
        self.detachDevice(dev);
        return null;
    }

    /// Tell the class driver, disable the slot and free the device's memory.
    fn detachDevice(self: *Softc, dev: *Device) void {
        if (dev.driver_detach) |f| f(dev.driver_ctx);
        dev.driver_detach = null;
        dev.intr.active = false;
        _ = self.command(0, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_DISABLE_SLOT) | xr.XHCI_TRB_SLOT_SET(dev.slot));
        self.dcbaa.ptr([*]volatile u64)[dev.slot] = 0;
        dmaFree(&dev.out_ctx);
        dmaFree(&dev.in_ctx);
        dmaFree(&dev.buf);
        dmaFree(&dev.ep0.dma);
        dmaFree(&dev.intr.ring.dma);
        if (dev.port < MAXPORTS) self.port_slot[dev.port] = 0;
        dev.active = false;
    }

    fn tick(self: *Softc) void {
        self.processEvents();
        for (self.devices[1 .. self.nslots + 1]) |*dev| {
            if (!dev.active or !dev.intr.active or !dev.intr.halted) continue;
            dev.intr.halted = false;
            self.recoverEndpoint(dev, dev.intr.dci, &dev.intr.ring);
            queueIntr(dev);
        }
        if (self.port_event) {
            self.port_event = false;
            self.scanPorts();
        }
    }
};

// -- the default control endpoint ----------------------------------------------------

fn ep0Event(dev: *Device, trb_pa: u64, cc: u32, remain: u32) void {
    if (!dev.ep0_busy) return;
    if (trb_pa == dev.ep0_data_pa) {
        dev.ep0_remain = remain;
        if (cc == xr.XHCI_TRB_ERROR_SUCCESS or cc == xr.XHCI_TRB_ERROR_SHORT_PKT) return;
    } else if (trb_pa != dev.ep0_status_pa and cc == xr.XHCI_TRB_ERROR_SUCCESS) {
        return;
    }
    dev.ep0_cc = cc;
    dev.ep0_busy = false;
    @as(*volatile bool, &dev.ep0_done).* = true;
}

/// Post a SETUP, an optional data stage at bus address `data_pa` and the
/// status stage, and ring the endpoint's doorbell.
fn startControl(dev: *Device, req: usb.DeviceRequest, data_pa: u64) void {
    const len: u32 = req.wLength;
    const dir_in: bool = (req.bmRequestType & usb.UT_READ) != 0;
    const setup: u64 = @as(u64, req.bmRequestType) | (@as(u64, req.bRequest) << 8) |
        (@as(u64, req.wValue) << 16) | (@as(u64, req.wIndex) << 32) | (@as(u64, req.wLength) << 48);
    const trt: u32 = if (len == 0) xr.XHCI_TRT_NONE else if (dir_in) xr.XHCI_TRT_IN else xr.XHCI_TRT_OUT;

    dev.ep0_done = false;
    dev.ep0_busy = true;
    dev.ep0_remain = 0;
    dev.ep0_cc = 0;
    _ = dev.ep0.push(setup, 8, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_SETUP_STAGE) | xr.XHCI_TRB_IDT | xr.XHCI_TRB_TRT(trt));
    dev.ep0_data_pa = 0;
    if (len > 0) {
        dev.ep0_data_pa = dev.ep0.push(data_pa, len, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_DATA_STAGE) |
            xr.XHCI_TRB_ISP | (if (dir_in) xr.XHCI_TRB_DIR_IN else 0));
    }
    const status_in: bool = len == 0 or !dir_in;
    dev.ep0_status_pa = dev.ep0.push(0, 0, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_STATUS_STAGE) |
        xr.XHCI_TRB_IOC | (if (status_in) xr.XHCI_TRB_DIR_IN else 0));
    dev.sc.doorbell(dev.slot, 1);
}

/// Run a control transfer and wait for it. `data` is read into (IN) or sent
/// (OUT); its length must equal `req.wLength`. Returns the bytes moved, or
/// null when the device stalled, failed or did not answer.
pub fn control(dev: *Device, req: usb.DeviceRequest, data: []u8) ?usize {
    const sc: *Softc = dev.sc;
    if (dev.ep0_busy and !sc.waitFor(&dev.ep0_done, 500)) return null;
    if (data.len != req.wLength or data.len > BUF_CTRL_SIZE) return null;
    const buf: [*]u8 = @ptrFromInt(dev.buf.va + BUF_CTRL);
    const dir_in: bool = (req.bmRequestType & usb.UT_READ) != 0;
    if (!dir_in) @memcpy(buf[0..data.len], data);

    startControl(dev, req, dev.buf.pa + BUF_CTRL);
    if (!sc.waitFor(&dev.ep0_done, 1000)) {
        // A transfer that never completes keeps the ring; give up on it.
        dev.ep0_busy = false;
        sc.recoverEndpoint(dev, 1, &dev.ep0);
        return null;
    }
    if (dev.ep0_cc != xr.XHCI_TRB_ERROR_SUCCESS and dev.ep0_cc != xr.XHCI_TRB_ERROR_SHORT_PKT) {
        sc.recoverEndpoint(dev, 1, &dev.ep0);
        return null;
    }
    const actual: usize = data.len - @min(data.len, dev.ep0_remain);
    if (dir_in) @memcpy(data[0..actual], buf[0..actual]);
    return actual;
}

/// Start a control transfer without waiting (for requests made from the
/// clock tick, such as the keyboard LEDs). Returns false when the default
/// endpoint is still busy; the caller tries again later.
pub fn controlAsync(dev: *Device, req: usb.DeviceRequest, data: []const u8) bool {
    if (dev.ep0_busy or data.len != req.wLength or data.len > BUF_ASYNC_SIZE) return false;
    const buf: [*]u8 = @ptrFromInt(dev.buf.va + BUF_ASYNC);
    @memcpy(buf[0..data.len], data);
    startControl(dev, req, dev.buf.pa + BUF_ASYNC);
    return true;
}

/// Change the default endpoint's packet size (Evaluate Context).
pub fn setMaxPacket0(dev: *Device, mps: u32) bool {
    const sc: *Softc = dev.sc;
    Softc.clearInputContext(dev);
    sc.ctx(dev.in_ctx, 0)[xr.XHCI_INCTX_ADD] = 0x2;
    const in_ep0: [*]volatile u32 = sc.ctx(dev.in_ctx, 2);
    const out_ep0: [*]volatile u32 = sc.ctx(dev.out_ctx, 1);
    var i: usize = 0;
    while (i < 5) : (i += 1) in_ep0[i] = out_ep0[i];
    in_ep0[0] &= ~@as(u32, 0x7); // the endpoint state is the controller's
    in_ep0[1] = (in_ep0[1] & 0xffff) | xr.XHCI_EPCTX_1_MAXP(mps);
    if (!sc.commandOk(dev.in_ctx.pa, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_EVALUATE_CTX) | xr.XHCI_TRB_SLOT_SET(dev.slot))) return false;
    dev.mps0 = mps;
    return true;
}

// -- the interrupt IN pipe --------------------------------------------------------------

fn queueIntr(dev: *Device) void {
    const p: *Pipe = &dev.intr;
    _ = p.ring.push(dev.buf.pa + BUF_INTR, p.mps, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_NORMAL) | xr.XHCI_TRB_IOC | xr.XHCI_TRB_ISP);
    dev.sc.doorbell(dev.slot, p.dci);
}

fn intrEvent(dev: *Device, cc: u32, remain: u32) void {
    const p: *Pipe = &dev.intr;
    if (cc != xr.XHCI_TRB_ERROR_SUCCESS and cc != xr.XHCI_TRB_ERROR_SHORT_PKT) {
        // The endpoint halted; the tick restarts it.
        p.halted = true;
        return;
    }
    const len: usize = p.mps - @min(p.mps, remain);
    const buf: [*]const u8 = @ptrFromInt(dev.buf.va + BUF_INTR);
    if (p.cb) |cb| cb(p.ctx, buf[0..len]);
    queueIntr(dev);
}

/// The xHCI endpoint interval for an interrupt endpoint: a power of two of
/// 125 us microframes. Low- and full-speed devices give bInterval in frames.
fn intrInterval(speed: u32, binterval: u8) u32 {
    if (speed == xr.XHCI_SPEED_LOW or speed == xr.XHCI_SPEED_FULL) {
        var frames: u32 = @max(binterval, 1);
        var log2: u32 = 0;
        while (frames > 1) : (frames >>= 1) log2 += 1;
        return @min(@max(log2 + 3, 3), 10);
    }
    return @min(@as(u32, @max(binterval, 1)) - 1, 15);
}

/// Configure the interrupt IN endpoint `ep` and start reading it; each
/// report is handed to `cb`.
pub fn openInterruptIn(dev: *Device, ep: *const usb.EndpointDescriptor, cb: IntrCallback, ctx: ?*anyopaque) bool {
    const sc: *Softc = dev.sc;
    const num: u32 = ep.bEndpointAddress & usb.UE_ADDR;
    const dci: u32 = num * 2 + 1;
    const mps: u32 = @min(@as(u32, ep.wMaxPacketSize) & 0x7ff, BUF_INTR_SIZE);
    if (num == 0 or mps == 0) return false;
    const p: *Pipe = &dev.intr;
    p.* = .{ .dci = dci, .mps = mps, .cb = cb, .ctx = ctx };
    if (!p.ring.init(sc)) return false;

    Softc.clearInputContext(dev);
    sc.ctx(dev.in_ctx, 0)[xr.XHCI_INCTX_ADD] = 0x1 | (@as(u32, 1) << @intCast(dci));
    const in_slot: [*]volatile u32 = sc.ctx(dev.in_ctx, 1);
    const out_slot: [*]volatile u32 = sc.ctx(dev.out_ctx, 0);
    var i: usize = 0;
    while (i < 4) : (i += 1) in_slot[i] = out_slot[i];
    const entries: u32 = @max((in_slot[0] >> 27) & 0x1f, dci);
    in_slot[0] = (in_slot[0] & ~(@as(u32, 0x1f) << 27)) | xr.XHCI_SCTX_0_CTX_NUM(entries);
    in_slot[3] = 0;

    const epc: [*]volatile u32 = sc.ctx(dev.in_ctx, 1 + dci);
    epc[0] = xr.XHCI_EPCTX_0_IVAL(intrInterval(dev.speed, ep.bInterval));
    epc[1] = xr.XHCI_EPCTX_1_CERR(3) | xr.XHCI_EPCTX_1_EPTYPE(xr.XHCI_EPTYPE_INT_IN) | xr.XHCI_EPCTX_1_MAXP(mps);
    const deq: u64 = p.ring.dma.pa | xr.XHCI_EPCTX_2_DCS;
    epc[2] = @truncate(deq);
    epc[3] = @truncate(deq >> 32);
    epc[4] = xr.XHCI_EPCTX_4_AVG_TRB_LEN(mps) | xr.XHCI_EPCTX_4_MAX_ESIT(mps);

    if (!sc.commandOk(dev.in_ctx.pa, xr.XHCI_TRB_TYPE_SET(xr.XHCI_TRB_TYPE_CONFIGURE_EP) | xr.XHCI_TRB_SLOT_SET(dev.slot))) {
        Softc.dmaFree(&p.ring.dma);
        return false;
    }
    p.active = true;
    queueIntr(dev);
    return true;
}

// -- PCI attachment -----------------------------------------------------------------------

var softc: [MAXUNITS]Softc = @splat(.{});
var nsoftc: usize = 0;

/// Intel PCH xHCI controllers whose USB 2.0 ports start out routed to EHCI
/// (FreeBSD's xhci_pci_port_route(), Linux's usb_enable_intel_xhci_ports()).
fn intelSwitchable(dev: *const pci.PciDev) bool {
    if (dev.vendor != 0x8086) return false;
    return switch (dev.device) {
        0x1e31, // Panther Point (7 Series)
        0x8c31, // Lynx Point (8 Series / C220)
        0x9c31, // Lynx Point-LP
        0x8cb1, // Wildcat Point (9 Series)
        0x9cb1, // Wildcat Point-LP
        => true,
        else => false,
    };
}

fn xhciProbe(dev: *const pci.PciDev) ?[]const u8 {
    if (dev.class != PCIC_SERIALBUS or dev.subclass != PCIS_SERIALBUS_USB or dev.progif != PCIP_SERIALBUS_USB_XHCI) return null;
    if (dev.bars[0].io or dev.bars[0].size == 0) return null;
    if (dev.vendor == 0x8086) {
        return switch (dev.device) {
            0x1e31 => "Intel Panther Point USB 3.0 controller",
            0x8c31 => "Intel Lynx Point USB 3.0 controller",
            0x9c31 => "Intel Lynx Point-LP USB 3.0 controller",
            0x8cb1 => "Intel Wildcat Point USB 3.0 controller",
            0x9cb1 => "Intel Wildcat Point-LP USB 3.0 controller",
            else => "Intel USB 3.0 controller",
        };
    }
    if (dev.vendor == 0x1b36 and dev.device == 0x000d) return "QEMU XHCI USB 3.0 controller";
    return "XHCI (generic) USB 3.0 controller";
}

fn xhciAttach(dev: *pci.PciDev, unit: u32, self_dev: *const subr_bus.Device) bool {
    if (nsoftc >= MAXUNITS) return false;
    const sc: *Softc = &softc[nsoftc];
    sc.* = .{ .unit = unit, .pcidev = dev };
    const base: u64 = arch.pmap.mapdev(dev.bars[0].base, dev.bars[0].size) orelse return false;
    sc.cap = base;
    sc.op = base + (Softc.rd4(base, xr.XHCI_CAPLENGTH) & 0xff);
    sc.rt = base + (Softc.rd4(base, xr.XHCI_RTSOFF) & ~@as(u32, 0x1f));
    sc.db = base + (Softc.rd4(base, xr.XHCI_DBOFF) & ~@as(u32, 0x3));

    pci.enable_busmaster(dev);
    if (!sc.start()) return false;
    nsoftc += 1;

    // CAPLENGTH and HCIVERSION share the first word; some controllers only
    // answer 32-bit reads.
    const version: u32 = Softc.rd4(base, xr.XHCI_CAPLENGTH) >> 16;
    subr_bus.device_printf(self_dev, "%u bytes context size, %s DMA, %u ports, %u slots\n", .{
        sc.ctx_size, if (sc.ac64) "64-bit" else "32-bit", sc.nports, sc.nslots,
    });
    const prefix: []const u8 = "usbus";
    @memcpy(sc.busname[0..prefix.len], prefix);
    sc.busname[prefix.len] = @intCast('0' + unit);
    sc.busname_len = prefix.len + 1;
    prf.printf("%s on xhci%u\n", .{ sc.busname[0..sc.busname_len], unit });
    prf.printf("%s: USB revision %u.%u\n", .{ sc.busname[0..sc.busname_len], version >> 8, (version >> 4) & 0xf });

    return true;
}

/// After the PCI scan, when the EHCI controllers have been taken from the
/// firmware (ehci_pci.zig): route the ports to the xHCI and attach what is
/// plugged in.
fn usbProbe(_: ?*const anyopaque) callconv(.c) void {
    for (softc[0..nsoftc]) |*sc| {
        const dev: *const pci.PciDev = sc.pcidev;
        if (intelSwitchable(dev)) {
            // SuperSpeed on every port that may have it, then the USB 2.0
            // ports, which drop off EHCI and reconnect here.
            pci.write_config(dev, xr.PCI_XHCI_INTEL_USB3_PSSEN, pci.read_config(dev, xr.PCI_XHCI_INTEL_USB3PRM, 4), 4);
            pci.write_config(dev, xr.PCI_XHCI_INTEL_XUSB2PR, pci.read_config(dev, xr.PCI_XHCI_INTEL_XUSB2PRM, 4), 4);
        }
        // Give the devices time to be seen and debounced, and look a few
        // times; later arrivals are found by the tick.
        arch.clock.DELAY(200_000);
        var round: u32 = 0;
        while (round < 5) : (round += 1) {
            sc.processEvents();
            sc.scanPorts();
            arch.clock.DELAY(100_000);
        }
        sc.port_event = false;
    }
}

fn xhciTick() void {
    for (softc[0..nsoftc]) |*sc| sc.tick();
}

var xhci_driver: pci.Driver = .{
    .name = "xhci",
    .probe = xhciProbe,
    .attach = xhciAttach,
};

fn xhciRegister(_: ?*const anyopaque) callconv(.c) void {
    pci.registerDriver(&xhci_driver);
    arch.clock.registerTickHandler(xhciTick);
}

comptime {
    sysinit.SYSINIT("sysinit_xhci", sysinit.SI_SUB_DRIVERS, sysinit.SI_ORDER_MIDDLE, xhciRegister, null);
    // Right after the PCI scan (SI_ORDER_MIDDLE).
    sysinit.SYSINIT("sysinit_usb_probe", sysinit.SI_SUB_CONFIGURE, sysinit.SI_ORDER_MIDDLE + 1, usbProbe, null);
}
