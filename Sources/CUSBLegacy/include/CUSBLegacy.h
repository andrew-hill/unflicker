#ifndef CUSBLEGACY_H
#define CUSBLEGACY_H

#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

// Creates an IOUSBDeviceInterface for a registry entry, or returns NULL with
// *code set to the failing call's result. The plugin type and interface UUIDs
// live on this side of the language boundary because they are
// CFUUIDGetConstantUUIDWithBytes macros: retyping their bytes into Swift is
// the transcription error that produces a confident false negative.
IOUSBDeviceInterface **CUSBLegacyCreateDeviceInterface(io_service_t service,
                                                       IOReturn *code);
void CUSBLegacyDestroyDeviceInterface(IOUSBDeviceInterface **device);

#endif
