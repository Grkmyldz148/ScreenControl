import Foundation
import IOKit

// MARK: - IOAVService (private IOKit SPI)
//
// Apple Silicon'da harici monitörle I2C/DDC konuşmanın tek yolu bu.
// Intel Mac'lerdeki IOFramebuffer + IOI2CInterface yolu M1/M2/M3'te yok;
// yerine DCP (Display Co-Processor) üzerinden IOAVService kullanılıyor.
// Semboller IOKit.framework içinde public header'sız olarak bulunuyor,
// bu yüzden @_silgen_name ile doğrudan bağlanıyoruz.

typealias IOAVServiceRef = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(
    _ allocator: CFAllocator?,
    _ service: io_service_t
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(
    _ service: CFTypeRef,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ outputBuffer: UnsafeMutableRawPointer,
    _ outputBufferSize: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(
    _ service: CFTypeRef,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ inputBuffer: UnsafeMutableRawPointer,
    _ inputBufferSize: UInt32
) -> IOReturn
