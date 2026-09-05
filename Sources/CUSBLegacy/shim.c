#include "CUSBLegacy.h"
#include <IOKit/IOCFPlugIn.h>

IOUSBDeviceInterface **CUSBLegacyCreateDeviceInterface(io_service_t service,
                                                       IOReturn *code) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(service,
                                                    kIOUSBDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID,
                                                    &plug, &score);
    if (kr != kIOReturnSuccess || plug == NULL) {
        if (code) *code = kr;
        return NULL;
    }

    IOUSBDeviceInterface **dev = NULL;
    HRESULT hr = (*plug)->QueryInterface(plug,
                                         CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                         (LPVOID *)&dev);
    IODestroyPlugInInterface(plug);
    if (hr != S_OK || dev == NULL) {
        // A COM HRESULT, not an IOReturn. Keep the number rather than
        // inventing a mapping.
        if (code) *code = (IOReturn)hr;
        return NULL;
    }
    if (code) *code = kIOReturnSuccess;
    return dev;
}

void CUSBLegacyDestroyDeviceInterface(IOUSBDeviceInterface **device) {
    if (device) (*device)->Release(device);
}
