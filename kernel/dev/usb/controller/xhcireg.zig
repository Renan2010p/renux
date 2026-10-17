// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// xHCI register and data-structure definitions.
//
// The Zig counterpart of FreeBSD's sys/dev/usb/controller/xhcireg.h: the
// capability, operational, runtime and doorbell registers, the transfer
// request block (TRB) and the device, slot and endpoint contexts of the
// eXtensible Host Controller Interface, revision 1.2.

/// PCI configuration: serial bus release number, and the Intel PCH port
/// routing registers (Panther Point and later, "xHCI/EHCI switching").
pub const PCI_XHCI_INTEL_XUSB2PR: u16 = 0xd0; // USB 2.0 ports routed to xHCI
pub const PCI_XHCI_INTEL_XUSB2PRM: u16 = 0xd4; // ... which of them may be
pub const PCI_XHCI_INTEL_USB3_PSSEN: u16 = 0xd8; // USB 3.0 SuperSpeed enabled
pub const PCI_XHCI_INTEL_USB3PRM: u16 = 0xdc; // ... which of them may be

// -- capability registers -------------------------------------------------------

pub const XHCI_CAPLENGTH: u64 = 0x00; // u8
pub const XHCI_HCIVERSION: u64 = 0x02; // u16
pub const XHCI_HCSPARAMS1: u64 = 0x04;
pub const XHCI_HCSPARAMS2: u64 = 0x08;
pub const XHCI_HCSPARAMS3: u64 = 0x0c;
pub const XHCI_HCCPARAMS1: u64 = 0x10;
pub const XHCI_DBOFF: u64 = 0x14;
pub const XHCI_RTSOFF: u64 = 0x18;

pub fn HCS1_DEVSLOT_MAX(x: u32) u32 {
    return x & 0xff;
}
pub fn HCS1_N_PORTS(x: u32) u32 {
    return (x >> 24) & 0xff;
}
/// Scratchpad buffers the controller wants: Max Scratchpad Bufs Hi:Lo.
pub fn HCS2_SPB_MAX(x: u32) u32 {
    return (((x >> 21) & 0x1f) << 5) | ((x >> 27) & 0x1f);
}
pub const HCC1_AC64: u32 = 1 << 0; // 64-bit addressing
pub const HCC1_CSZ: u32 = 1 << 2; // 64-byte contexts
pub const HCC1_PPC: u32 = 1 << 3; // port power control
/// First extended capability, in 32-bit words from the base.
pub fn HCC1_XECP(x: u32) u32 {
    return (x >> 16) & 0xffff;
}

// -- extended capabilities ------------------------------------------------------

pub const XHCI_ID_USB_LEGACY: u32 = 1;
pub const XHCI_ID_PROTOCOLS: u32 = 2;

pub fn XHCI_XECP_ID(x: u32) u32 {
    return x & 0xff;
}
pub fn XHCI_XECP_NEXT(x: u32) u32 {
    return (x >> 8) & 0xff;
}
/// USB Legacy Support capability: BIOS and OS ownership semaphores.
pub const XHCI_XECP_BIOS_SEM: u32 = 1 << 16;
pub const XHCI_XECP_OS_SEM: u32 = 1 << 24;
/// USB Legacy Support Control/Status (the word after the capability): the
/// SMI enables (bits 0, 4, 13-15) and the RW1C SMI events (bits 29-31).
pub const XHCI_XECP_LEGCTLSTS_ENABLES: u32 = 0x0000_e011;
pub const XHCI_XECP_LEGCTLSTS_EVENTS: u32 = 0xe000_0000;

// -- operational registers (from CAPLENGTH) -----------------------------------------

pub const XHCI_USBCMD: u64 = 0x00;
pub const XHCI_CMD_RS: u32 = 1 << 0; // run/stop
pub const XHCI_CMD_HCRST: u32 = 1 << 1; // host controller reset
pub const XHCI_CMD_INTE: u32 = 1 << 2; // interrupter enable
pub const XHCI_USBSTS: u64 = 0x04;
pub const XHCI_STS_HCH: u32 = 1 << 0; // halted
pub const XHCI_STS_HSE: u32 = 1 << 2; // host system error
pub const XHCI_STS_EINT: u32 = 1 << 3; // event interrupt
pub const XHCI_STS_PCD: u32 = 1 << 4; // port change detect
pub const XHCI_STS_CNR: u32 = 1 << 11; // controller not ready
pub const XHCI_PAGESIZE: u64 = 0x08;
pub const XHCI_CRCR_LO: u64 = 0x18;
pub const XHCI_CRCR_HI: u64 = 0x1c;
pub const XHCI_CRCR_RCS: u32 = 1 << 0; // ring cycle state
pub const XHCI_DCBAAP_LO: u64 = 0x30;
pub const XHCI_DCBAAP_HI: u64 = 0x34;
pub const XHCI_CONFIG: u64 = 0x38;

/// Port register set `port` (1-based).
pub fn XHCI_PORTSC(port: u32) u64 {
    return 0x400 + 0x10 * @as(u64, port - 1);
}
pub const XHCI_PS_CCS: u32 = 1 << 0; // current connect status
pub const XHCI_PS_PED: u32 = 1 << 1; // port enabled (RW1C: writing 1 disables)
pub const XHCI_PS_OCA: u32 = 1 << 3; // over-current active
pub const XHCI_PS_PR: u32 = 1 << 4; // port reset
pub const XHCI_PS_PLS_MASK: u32 = 0xf << 5; // port link state
pub const XHCI_PS_PP: u32 = 1 << 9; // port power
pub const XHCI_PS_SPEED_MASK: u32 = 0xf << 10;
pub const XHCI_PS_PIC_MASK: u32 = 0x3 << 14; // port indicator
pub const XHCI_PS_CSC: u32 = 1 << 17; // connect status change
pub const XHCI_PS_PEC: u32 = 1 << 18;
pub const XHCI_PS_WRC: u32 = 1 << 19;
pub const XHCI_PS_OCC: u32 = 1 << 20;
pub const XHCI_PS_PRC: u32 = 1 << 21; // port reset change
pub const XHCI_PS_PLC: u32 = 1 << 22;
pub const XHCI_PS_CEC: u32 = 1 << 23;
pub const XHCI_PS_CHANGES: u32 = XHCI_PS_CSC | XHCI_PS_PEC | XHCI_PS_WRC | XHCI_PS_OCC | XHCI_PS_PRC | XHCI_PS_PLC | XHCI_PS_CEC;
pub const XHCI_PS_WAKE_MASK: u32 = 0x7 << 25;
pub const XHCI_PS_DR: u32 = 1 << 30; // device removable

/// The bits of PORTSC that may be written back unchanged: everything that
/// is neither a RW1C change bit, PED, nor a self-clearing command.
pub const XHCI_PS_PRESERVE: u32 = XHCI_PS_CCS | XHCI_PS_OCA | XHCI_PS_SPEED_MASK | XHCI_PS_DR |
    XHCI_PS_PLS_MASK | XHCI_PS_PP | XHCI_PS_PIC_MASK | XHCI_PS_WAKE_MASK;

pub fn XHCI_PS_SPEED(x: u32) u32 {
    return (x >> 10) & 0xf;
}

/// Port speeds (the default Protocol Speed IDs), as PORTSC and the slot
/// context give them.
pub const XHCI_SPEED_FULL: u32 = 1;
pub const XHCI_SPEED_LOW: u32 = 2;
pub const XHCI_SPEED_HIGH: u32 = 3;
pub const XHCI_SPEED_SUPER: u32 = 4;

// -- runtime registers (from RTSOFF) ------------------------------------------------

/// Interrupter `n` register set.
pub fn XHCI_IMAN(n: u64) u64 {
    return 0x20 + 0x20 * n;
}
pub fn XHCI_IMOD(n: u64) u64 {
    return 0x24 + 0x20 * n;
}
pub fn XHCI_ERSTSZ(n: u64) u64 {
    return 0x28 + 0x20 * n;
}
pub fn XHCI_ERSTBA_LO(n: u64) u64 {
    return 0x30 + 0x20 * n;
}
pub fn XHCI_ERSTBA_HI(n: u64) u64 {
    return 0x34 + 0x20 * n;
}
pub fn XHCI_ERDP_LO(n: u64) u64 {
    return 0x38 + 0x20 * n;
}
pub fn XHCI_ERDP_HI(n: u64) u64 {
    return 0x3c + 0x20 * n;
}
pub const XHCI_IMAN_INTR_PEND: u32 = 1 << 0;
pub const XHCI_IMAN_INTR_ENA: u32 = 1 << 1;
pub const XHCI_ERDP_BUSY: u32 = 1 << 3; // event handler busy (RW1C)

// -- transfer request blocks --------------------------------------------------------

pub const Trb: type = extern struct {
    param: u64,
    status: u32,
    control: u32,
};

pub const XHCI_TRB_CYCLE: u32 = 1 << 0;
pub const XHCI_TRB_TC: u32 = 1 << 1; // Link TRB: toggle cycle
pub const XHCI_TRB_ISP: u32 = 1 << 2; // interrupt on short packet
pub const XHCI_TRB_IOC: u32 = 1 << 5; // interrupt on completion
pub const XHCI_TRB_IDT: u32 = 1 << 6; // immediate data
pub const XHCI_TRB_DIR_IN: u32 = 1 << 16; // Data/Status stage direction

pub fn XHCI_TRB_TYPE_SET(t: u32) u32 {
    return t << 10;
}
pub fn XHCI_TRB_TYPE_GET(x: u32) u32 {
    return (x >> 10) & 0x3f;
}
pub fn XHCI_TRB_SLOT_SET(s: u32) u32 {
    return s << 24;
}
pub fn XHCI_TRB_SLOT_GET(x: u32) u32 {
    return (x >> 24) & 0xff;
}
pub fn XHCI_TRB_EP_GET(x: u32) u32 {
    return (x >> 16) & 0x1f;
}
/// Setup Stage: transfer type (0 no data, 2 OUT data, 3 IN data).
pub fn XHCI_TRB_TRT(t: u32) u32 {
    return t << 16;
}
pub const XHCI_TRT_NONE: u32 = 0;
pub const XHCI_TRT_OUT: u32 = 2;
pub const XHCI_TRT_IN: u32 = 3;
/// Event status: completion code and residual length.
pub fn XHCI_TRB_ERROR_GET(x: u32) u32 {
    return (x >> 24) & 0xff;
}
pub fn XHCI_TRB_REMAIN_GET(x: u32) u32 {
    return x & 0xffffff;
}

pub const XHCI_TRB_TYPE_NORMAL: u32 = 1;
pub const XHCI_TRB_TYPE_SETUP_STAGE: u32 = 2;
pub const XHCI_TRB_TYPE_DATA_STAGE: u32 = 3;
pub const XHCI_TRB_TYPE_STATUS_STAGE: u32 = 4;
pub const XHCI_TRB_TYPE_LINK: u32 = 6;
pub const XHCI_TRB_TYPE_ENABLE_SLOT: u32 = 9;
pub const XHCI_TRB_TYPE_DISABLE_SLOT: u32 = 10;
pub const XHCI_TRB_TYPE_ADDRESS_DEVICE: u32 = 11;
pub const XHCI_TRB_TYPE_CONFIGURE_EP: u32 = 12;
pub const XHCI_TRB_TYPE_EVALUATE_CTX: u32 = 13;
pub const XHCI_TRB_TYPE_RESET_EP: u32 = 14;
pub const XHCI_TRB_TYPE_SET_TR_DEQUEUE: u32 = 16;
pub const XHCI_TRB_EVENT_TRANSFER: u32 = 32;
pub const XHCI_TRB_EVENT_CMD_COMPLETE: u32 = 33;
pub const XHCI_TRB_EVENT_PORT_STS_CHANGE: u32 = 34;

/// Completion codes.
pub const XHCI_TRB_ERROR_SUCCESS: u32 = 1;
pub const XHCI_TRB_ERROR_STALL: u32 = 6;
pub const XHCI_TRB_ERROR_SHORT_PKT: u32 = 13;

/// An Event Ring Segment Table entry.
pub const ErstEntry: type = extern struct {
    base: u64,
    size: u32,
    reserved: u32,
};

// -- contexts -----------------------------------------------------------------------
//
// Every context is 32 bytes, or 64 when HCCPARAMS1.CSZ is set (the upper
// half is then reserved). A device context is the slot context followed by
// 31 endpoint contexts; an input context puts the input control context in
// front. Endpoint context `dci` (device context index: endpoint number times
// two, plus one for IN; the default control endpoint is 1) is entry `dci`.

/// Input control context: dword 0 drop flags, dword 1 add flags.
pub const XHCI_INCTX_DROP: usize = 0;
pub const XHCI_INCTX_ADD: usize = 1;

/// Slot context dword 0.
pub fn XHCI_SCTX_0_SPEED(s: u32) u32 {
    return s << 20;
}
pub fn XHCI_SCTX_0_CTX_NUM(n: u32) u32 {
    return n << 27;
}
/// Slot context dword 1.
pub fn XHCI_SCTX_1_RH_PORT(p: u32) u32 {
    return p << 16;
}

/// Endpoint context dword 0.
pub fn XHCI_EPCTX_0_IVAL(i: u32) u32 {
    return i << 16;
}
/// Endpoint context dword 1.
pub fn XHCI_EPCTX_1_CERR(n: u32) u32 {
    return n << 1;
}
pub fn XHCI_EPCTX_1_EPTYPE(t: u32) u32 {
    return t << 3;
}
pub fn XHCI_EPCTX_1_MAXP(n: u32) u32 {
    return n << 16;
}
/// Endpoint context dword 4: average TRB length, max ESIT payload.
pub fn XHCI_EPCTX_4_AVG_TRB_LEN(n: u32) u32 {
    return n;
}
pub fn XHCI_EPCTX_4_MAX_ESIT(n: u32) u32 {
    return n << 16;
}
/// Dequeue cycle state, in the low bit of the TR dequeue pointer.
pub const XHCI_EPCTX_2_DCS: u64 = 1;

pub const XHCI_EPTYPE_CTRL: u32 = 4;
pub const XHCI_EPTYPE_INT_IN: u32 = 7;
