//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Adds HPACK-conformant Huffman encoding to `ByteBuffer`. Note that the implementation is *not*
/// thread safe. The intended use is to be within a single HTTP2StreamChannel or similar, on a
/// single EventLoop.
extension ByteBuffer {
    fileprivate struct _EncoderState {
        var offset = 0
        var remainingBits = 8
    }
    
    /// Returns the number of *bits* required to encode a given string.
    fileprivate static func encodedBitLength<C : Collection>(of bytes: C) -> Int where C.Element == UInt8 {
        let clen = bytes.reduce(0) { $0 + StaticHuffmanTable[Int($1)].nbits }
        // round up to nearest multiple of 8 for EOS prefix
        return (clen + 7) & ~7
    }
    
    /// Returns the number of bytes required to encode a given string.
    static func huffmanEncodedLength<C : Collection>(of bytes: C) -> Int where C.Element == UInt8 {
        return self.encodedBitLength(of: bytes) / 8
    }
    
    /// Encodes the given string to the buffer, using HPACK Huffman encoding.
    ///
    /// - Parameter string: The string data to encode.
    /// - Returns: The number of bytes used while encoding the string.
    @discardableResult
    mutating func setHuffmanEncoded<C: Collection>(bytes stringBytes: C) -> Int where C.Element == UInt8 {
        let clen = ByteBuffer.encodedBitLength(of: stringBytes)
        self.ensureBitsAvailable(clen)
        
        return self.withUnsafeMutableWritableBytes { bytes in
            var state = _EncoderState()
            
            for ch in stringBytes {
                ByteBuffer.appendSym_fast(StaticHuffmanTable[Int(ch)], &state, bytes: bytes)
            }
            
            if state.remainingBits > 0 && state.remainingBits < 8 {
                // set all remaining bits of the last byte to 1
                bytes[state.offset] |= UInt8(1 << state.remainingBits) - 1
                state.offset += 1
                state.remainingBits = (state.offset == bytes.count ? 0 : 8)
            }
            
            return state.offset
        }
    }
    
    @discardableResult
    mutating func writeHuffmanEncoded<C: Collection>(bytes stringBytes: C) -> Int where C.Element == UInt8 {
        let written = self.setHuffmanEncoded(bytes: stringBytes)
        self.moveWriterIndex(forwardBy: written)
        return written
    }
    
    fileprivate static func appendSym_fast(_ sym: HuffmanTableEntry, _ state: inout _EncoderState, bytes: UnsafeMutableRawBufferPointer) {
        // will it fit as-is?
        if sym.nbits == state.remainingBits {
            bytes[state.offset] |= UInt8(sym.bits)
            state.offset += 1
            state.remainingBits = state.offset == bytes.count ? 0 : 8
        } else if sym.nbits < state.remainingBits {
            let diff = state.remainingBits - sym.nbits
            bytes[state.offset] |= UInt8(sym.bits << diff)
            state.remainingBits -= sym.nbits
        } else {
            var (code, nbits) = sym
            
            nbits -= state.remainingBits
            bytes[state.offset] |= UInt8(code >> nbits)
            state.offset += 1
            
            if nbits & 0x7 != 0 {
                // align code to MSB
                code <<= 8 - (nbits & 0x7)
            }
            
            // we can short-circuit if less than 8 bits are remaining
            if nbits < 8 {
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
                state.remainingBits = 8 - nbits
                return
            }
            
            // longer path for larger amounts
            switch nbits {
            case _ where nbits > 24:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 24)
                nbits -= 8
                state.offset += 1
                fallthrough
            case _ where nbits > 16:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 16)
                nbits -= 8
                state.offset += 1
                fallthrough
            case _ where nbits > 8:
                bytes[state.offset] = UInt8(truncatingIfNeeded: code >> 8)
                nbits -= 8
                state.offset += 1
            default:
                break
            }
            
            if nbits == 8 {
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
                state.offset += 1
                state.remainingBits = state.offset == bytes.count ? 0 : 8
            } else {
                state.remainingBits = 8 - nbits
                bytes[state.offset] = UInt8(truncatingIfNeeded: code)
            }
        }
    }
    
    fileprivate mutating func ensureBitsAvailable(_ bits: Int) {
        let bytesNeeded = bits / 8
        if bytesNeeded <= self.writableBytes {
            // just zero the requested number of bytes before we start OR-ing in our values
            self.withUnsafeMutableWritableBytes { ptr in
                ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).assign(repeating: 0, count: bytesNeeded)
            }
            return
        }
        
        let neededToAdd = bytesNeeded - self.writableBytes
        let newLength = self.capacity + neededToAdd
        
        // reallocate to ensure we have the room we need
        self.changeCapacity(to: newLength)
        
        // now zero all writable bytes that we expect to use
        self.withUnsafeMutableWritableBytes { ptr in
            ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).assign(repeating: 0, count: bytesNeeded)
        }
    }
}

/// Errors that may be encountered by the Huffman decoder.
public enum HuffmanDecodeError
{
    /// The decoder entered an invalid state. Usually this means invalid input.
    public struct InvalidState : NIOHPACKError {
        fileprivate init() {}
    }
    
    /// The output data could not be validated as UTF-8.
    public struct InvalidUTF8 : NIOHPACKError {
        fileprivate init() {}
    }
}

/// The decoder table. This structure doesn't actually take up any space, I think?
fileprivate let decoderTable = HuffmanDecoderTable()

extension ByteBuffer {
    
    /// Decodes a huffman-encoded string into a provided `ByteBuffer`.
    ///
    /// - Parameter at: The location of the encoded bytes to read.
    /// - Parameter length: The number of huffman-encoded octets to read.
    /// - Parameter output: A `ByteBuffer` into which decoded UTF-8 octets will be
    ///                     written.
    /// - Returns: The number of UTF-8 characters written into the output `ByteBuffer`.
    /// - Throws: HuffmanDecodeError if the data could not be decoded.
    @discardableResult
    func getHuffmanEncodedString(at index: Int, length: Int, into output: inout ByteBuffer) throws -> Int {
        precondition(index + length <= self.capacity, "Requested range out of bounds: \(index ..< index+length) vs. \(self.capacity)")
        if length == 0 {
            return 0
        }
        
        var state: UInt8 = 0
        var acceptable = false
        let start = output.writerIndex
        
        for ch in self.viewBytes(at: index, length: length) {
            var t = decoderTable[state: state, nybble: ch >> 4]
            if t.flags.contains(.failure) {
                throw HuffmanDecodeError.InvalidState()
            }
            if t.flags.contains(.symbol) {
                output.write(integer: t.sym)
            }
            
            t = decoderTable[state: t.state, nybble: ch & 0xf]
            if t.flags.contains(.failure) {
                throw HuffmanDecodeError.InvalidState()
            }
            if t.flags.contains(.symbol) {
                output.write(integer: t.sym)
            }
            
            state = t.state
            acceptable = t.flags.contains(.accepted)
        }
        
        guard acceptable else {
            throw HuffmanDecodeError.InvalidState()
        }
        
        return output.writerIndex - start
    }
    
    /// Reads a huffman-encoded string into a provided `ByteBuffer`, starting at the buffer's
    /// current `readerIndex`. Updates the `readerIndex` when it completes.
    ///
    /// - Parameter length: The number of huffman-encoded octets to read.
    /// - Parameter output: A `ByteBuffer` into which decoded UTF-8 octets will be
    ///                     written.
    /// - Returns: The number of UTF-8 characters written into the output `ByteBuffer`.
    /// - Throws: HuffmanDecodeError if the data could not be decoded.
    @discardableResult
    mutating func readHuffmanEncodedString(of length: Int, into output: inout ByteBuffer) throws -> Int {
        let result = try self.getHuffmanEncodedString(at: self.readerIndex, length: length, into: &output)
        self.moveReaderIndex(forwardBy: length)
        return result
    }
}
