// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 The Renux Project
//
// USB definitions.
//
// The Zig counterpart of FreeBSD's sys/dev/usb/usb.h: the standard device
// requests, descriptor types and the device, configuration, interface and
// endpoint descriptors of the USB 2.0 specification, chapter 9, plus the HID
// class requests (usbhid.h) the boot keyboard needs.

/// A SETUP packet (usb_device_request_t).
pub const DeviceRequest: type = extern struct {
    bmRequestType: u8,
    bRequest: u8,
    wValue: u16 align(1),
    wIndex: u16 align(1),
    wLength: u16 align(1),
};

/// bmRequestType.
pub const UT_READ: u8 = 0x80;
pub const UT_WRITE: u8 = 0x00;
pub const UT_STANDARD: u8 = 0x00;
pub const UT_CLASS: u8 = 0x20;
pub const UT_DEVICE: u8 = 0x00;
pub const UT_INTERFACE: u8 = 0x01;
pub const UT_READ_DEVICE: u8 = UT_READ | UT_STANDARD | UT_DEVICE;
pub const UT_WRITE_DEVICE: u8 = UT_WRITE | UT_STANDARD | UT_DEVICE;
pub const UT_WRITE_CLASS_INTERFACE: u8 = UT_WRITE | UT_CLASS | UT_INTERFACE;

/// Standard requests.
pub const UR_GET_DESCRIPTOR: u8 = 0x06;
pub const UR_SET_CONFIG: u8 = 0x09;

/// HID class requests.
pub const UR_SET_REPORT: u8 = 0x09;
pub const UR_SET_IDLE: u8 = 0x0a;
pub const UR_SET_PROTOCOL: u8 = 0x0b;
/// SET_REPORT report type, in the high byte of wValue.
pub const UHID_OUTPUT_REPORT: u16 = 0x02;

/// Descriptor types.
pub const UDESC_DEVICE: u8 = 0x01;
pub const UDESC_CONFIG: u8 = 0x02;
pub const UDESC_STRING: u8 = 0x03;
pub const UDESC_INTERFACE: u8 = 0x04;
pub const UDESC_ENDPOINT: u8 = 0x05;

pub const DeviceDescriptor: type = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bcdUSB: u16 align(1),
    bDeviceClass: u8,
    bDeviceSubClass: u8,
    bDeviceProtocol: u8,
    bMaxPacketSize: u8,
    idVendor: u16 align(1),
    idProduct: u16 align(1),
    bcdDevice: u16 align(1),
    iManufacturer: u8,
    iProduct: u8,
    iSerialNumber: u8,
    bNumConfigurations: u8,
};

pub const ConfigDescriptor: type = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    wTotalLength: u16 align(1),
    bNumInterface: u8,
    bConfigurationValue: u8,
    iConfiguration: u8,
    bmAttributes: u8,
    bMaxPower: u8,
};

pub const InterfaceDescriptor: type = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bInterfaceNumber: u8,
    bAlternateSetting: u8,
    bNumEndpoints: u8,
    bInterfaceClass: u8,
    bInterfaceSubClass: u8,
    bInterfaceProtocol: u8,
    iInterface: u8,
};

pub const EndpointDescriptor: type = extern struct {
    bLength: u8,
    bDescriptorType: u8,
    bEndpointAddress: u8,
    bmAttributes: u8,
    wMaxPacketSize: u16 align(1),
    bInterval: u8,
};

/// bEndpointAddress: direction bit and endpoint number.
pub const UE_DIR_IN: u8 = 0x80;
pub const UE_ADDR: u8 = 0x0f;
/// bmAttributes: transfer type.
pub const UE_XFERTYPE: u8 = 0x03;
pub const UE_INTERRUPT: u8 = 0x03;

/// Interface classes.
pub const UICLASS_HID: u8 = 0x03;
pub const UISUBCLASS_BOOT: u8 = 0x01;
pub const UIPROTO_BOOT_KEYBOARD: u8 = 0x01;
pub const UIPROTO_MOUSE: u8 = 0x02;

comptime {
    if (@sizeOf(DeviceRequest) != 8) @compileError("usb: DeviceRequest must be 8 bytes");
    if (@sizeOf(DeviceDescriptor) != 18) @compileError("usb: DeviceDescriptor must be 18 bytes");
    if (@sizeOf(ConfigDescriptor) != 9) @compileError("usb: ConfigDescriptor must be 9 bytes");
    if (@sizeOf(InterfaceDescriptor) != 9) @compileError("usb: InterfaceDescriptor must be 9 bytes");
    if (@sizeOf(EndpointDescriptor) != 7) @compileError("usb: EndpointDescriptor must be 7 bytes");
}
