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

import XCTest
import NIO
@testable import NIOHPACK

class HPACKIntegrationTests : XCTestCase {
    
    private let hpackTestsURL: URL = {
        let myURL = URL(fileURLWithPath: #file, isDirectory: false)
        let result: URL
        if #available(OSX 10.11, iOS 9.0, *) {
            result = URL(fileURLWithPath: "../../hpack-test-case", isDirectory: true, relativeTo: myURL).absoluteURL
        } else {
            // Fallback on earlier versions
            result = URL(string: "../../hpack-test-case", relativeTo: myURL)!.absoluteURL
        }
        return result
    }()
    
    private enum TestType : String, CaseIterable {
        case encoding = "raw-data"
        
        case swiftNIOPlain = "swift-nio-hpack-plain-text"
        case swiftNIOHuffman = "swift-nio-hpack-huffman"
        case node = "node-http2-hpack"
        case python = "python-hpack"
        case go = "go-hpack"
        
        case nghttp2
        case nghttp2ChangeTableSize = "nghttp2-change-table-size"
        case nghttp2LargeTables = "nghttp2-16384-4096"
        
        case haskellStatic = "haskell-http2-static"
        case haskellStaticHuffman = "haskell-http2-static-huffman"
        case haskellNaive = "haskell-http2-naive"
        case haskellNaiveHuffman = "haskell-http2-naive-huffman"
        case haskellLinear = "haskell-http2-linear"
        case haskellLinearHuffman = "haskell-http2-linear-huffman"
    }
    
    private func getSourceURL(for type: TestType) -> URL {
        return self.hpackTestsURL.appendingPathComponent(type.rawValue, isDirectory: true).absoluteURL
    }
    
    private func loadStories(for test: TestType) -> [HPACKStory] {
        let url = self.getSourceURL(for: test)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]).sorted(by: {$0.lastPathComponent < $1.lastPathComponent}) else {
            return []
        }
        
        let decoder = JSONDecoder()
        
        do {
            var stories = try contents.compactMap { url -> HPACKStory? in
                // for some reason using filter({ $0.pathExtension == "json" }) throws the compiler type-checker for a loop
                guard url.pathExtension == "json" else { return nil }
                let data = try Data(contentsOf: url, options: [.uncached, .mappedIfSafe])
                return try decoder.decode(HPACKStory.self, from: data)
            }
            
            // ensure there are valid non-zero sequence numbers
            // to ensure we modify these value types in-place we apparently need to use collection subscripting for all accesses
            // it seems that if there are sequence numbers on any cases they're on all cases; we can optimize for that.
            for idx in stories.indices where stories[idx].cases.count > 1 && stories[idx].cases[1].seqno == 0 {
                for cidx in stories[idx].cases.indices {
                    stories[idx].cases[cidx].seqno = cidx
                }
            }
            return stories
        } catch {
            XCTFail("Failed to decode encoder stories from JSON files")
            return []
        }
    }
    
    // funky names to ensure the encoder tests run before the decoder tests.
    func testAAEncoderWithoutHuffmanCoding() throws {
        ringViewCount = 0
        ringViewCopyCount = 0
        
        let stories = loadStories(for: .encoding)
        guard stories.count > 0 else {
            // we don't have the data, so don't go failing any tests
            return
        }
        
        let outputDir = getSourceURL(for: .swiftNIOPlain)
        if FileManager.default.fileExists(atPath: outputDir.path) == false {
            try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        for (idx, story) in stories.enumerated() {
            print("Non-Huffman encode story \(idx), context = \(story.context?.rawValue ?? "<none>")")
            if let desc = story.description {
                print(desc)
            }
            
            let encoded = runEncodeStory(story, idx, huffmanEncoded: false)
            writeOutputStory(encoded, at: idx, to: outputDir)
        }
        
        print("Ring buffer views created: \(ringViewCount). Number which required copies: \(ringViewCopyCount). Ratio: \(Double(ringViewCopyCount) / Double(ringViewCount) * 100)%")
    }
    
    // funky names to ensure the encoder tests run before the decoder tests.
    func testABEncoderWithHuffmanCoding() throws {
        ringViewCount = 0
        ringViewCopyCount = 0
        
        let stories = loadStories(for: .encoding)
        guard stories.count > 0 else {
            // we don't have the data, so don't go failing any tests
            return
        }
        
        let outputDir = getSourceURL(for: .swiftNIOHuffman)
        if FileManager.default.fileExists(atPath: outputDir.path) == false {
            try! FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        for (idx, story) in stories.enumerated() {
            print("Huffman encode story \(idx), context = \(story.context?.rawValue ?? "<none>")")
            if let desc = story.description {
                print(desc)
            }
            
            let encoded = runEncodeStory(story, idx)
            writeOutputStory(encoded, at: idx, to: outputDir)
        }
        
        print("Ring buffer views created: \(ringViewCount). Number which required copies: \(ringViewCopyCount). Ratio: \(Double(ringViewCopyCount) / Double(ringViewCount) * 100)%")
    }
    
    func testDecoder() {
        ringViewCount = 0
        ringViewCopyCount = 0
        
        for test in TestType.allCases where test != .encoding {
            _testDecoder(for: test)
        }
        
        print("Ring buffer views created: \(ringViewCount). Number which required copies: \(ringViewCopyCount). Ratio: \(Double(ringViewCopyCount) / Double(ringViewCount) * 100)%")
    }
    
    private func _testDecoder(for test: TestType) {
        print("Loading \(test.rawValue)...")
        let stories = loadStories(for: test)
        guard stories.count > 0 else {
            // no input data = no problems
            return
        }
        
        for (idx, story) in stories.enumerated() {
            print("Decode story \(idx), context = \(story.context?.rawValue ?? "<none>")")
            if let desc = story.description {
                print(desc)
            }
            
            var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
            
            for testCase in story.cases {
                do {
                    if let size = testCase.headerTableSize {
                        decoder.maxDynamicTableLength = size
                    }
                    
                    guard var bytes = testCase.wire else {
                        XCTFail("Decoder story case \(testCase.seqno) has no wire data to decode!")
                        return
                    }
                    let decoded = try decoder.decodeHeaders(from: &bytes)
                    XCTAssertEqual(testCase.headers, decoded)
                } catch {
                    print("  \(testCase.seqno) - failed.")
                    XCTFail("Failure in story \(idx), case \(testCase.seqno) - \(error)")
                }
            }
        }
    }
    
    private func writeOutputStory(_ story: HPACKStory, at index: Int, to directory: URL) {
        let outURL = directory
            .appendingPathComponent(String(format: "story_%02d", index), isDirectory: false)
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.keyEncodingStrategy = .convertToSnakeCase
        
        do {
            let data = try encoder.encode(story)
            try data.write(to: outURL, options: [.atomic])
        } catch {
            print("Error writing encoded test case: \(error)")
        }
    }
    
    private func runEncodeStory(_ story: HPACKStory, _ index: Int, huffmanEncoded: Bool = true) -> HPACKStory {
        // do we need to care about the context?
        var encoder = HPACKEncoder(allocator: ByteBufferAllocator(), useHuffmanEncoding: huffmanEncoded)
        var decoder = HPACKDecoder(allocator: ByteBufferAllocator())
        
        var result = story
        result.cases.removeAll()
        
        for storyCase in story.cases {
            do {
                if let tableSize = storyCase.headerTableSize {
                    encoder.setMaxDynamicTableSize(tableSize)
                    decoder.maxDynamicTableLength = tableSize
                }
                
                try encoder.append(headers: storyCase.headers)
                
                var outputCase = storyCase
                var encoded = encoder.encodedData
                outputCase.wire = encoded
                encoder.reset()
                result.cases.append(outputCase)
                
                // now try to decode it
                let decoded = try decoder.decodeHeaders(from: &encoded)
                XCTAssertEqual(storyCase.headers, decoded)
            } catch {
                print("  \(storyCase.seqno) - failed.")
                XCTFail("Failure in story \(index), case \(storyCase.seqno) - \(error)")
            }
        }
        
        // the output story now has all the wire values filled in
        return result
    }
    
}

struct HPACKStory : Codable {
    var context: HPACKStoryContext?
    var description: String?
    var cases: [HPACKStoryCase]
}

enum HPACKStoryContext : String, Codable {
    case request
    case response
}

struct HPACKStoryCase : Codable {
    var seqno: Int
    var headerTableSize: Int?
    var wire: ByteBuffer?
    var headers: HPACKHeaders
    
    private enum Keys : String, CodingKey {
        case seqno
        case headerTableSize = "header_table_size"
        case wire
        case headers
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.seqno = try container.decodeIfPresent(Int.self, forKey: .seqno) ?? 0
        self.headerTableSize = try container.decodeIfPresent(Int.self, forKey: .headerTableSize)
        
        if let wireString = try container.decodeIfPresent(String.self, forKey: .wire) {
            self.wire = decodeHexData(from: wireString)
        } else {
            self.wire = nil
        }
        
        let rawHeaders = try container.decode([[String : String]].self, forKey: .headers)
        let pairs = rawHeaders.map { ($0.first!.key, $0.first!.value) }
        self.headers = HPACKHeaders(pairs)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(self.seqno, forKey: .seqno)
        try container.encode(self.headerTableSize, forKey: .headerTableSize)
        
        if let bytes = self.wire {
            try container.encode(encodeHex(data: bytes), forKey: .wire)
        }
        
        let rawHeaders = self.headers.map { [$0.0 : $0.1] }
        try container.encode(rawHeaders, forKey: .headers)
    }
}

fileprivate func decodeHexData(from string: String) -> ByteBuffer {
    var bytes: [UInt8] = []
    var idx = string.startIndex
    
    repeat {
        let byteStr = string[idx...string.index(after: idx)]
        bytes.append(UInt8(byteStr, radix: 16)!)
        idx = string.index(idx, offsetBy: 2)
        
    } while string.distance(from: idx, to: string.endIndex) > 1
    
    var buf = ByteBufferAllocator().buffer(capacity: bytes.count)
    buf.write(bytes: bytes)
    return buf
}

fileprivate func encodeHex(data: ByteBuffer) -> String {
    var result = ""
    for byte in data.readableBytesView {
        let str = String(byte, radix: 16)
        if str.count == 1 {
            result.append("0")
        }
        result.append(str)
    }
    return result
}

extension ByteBufferView : CustomDebugStringConvertible {
    public var debugDescription: String {
        var desc = "\(self.count) bytes: ["
        for byte in self {
            let hexByte = String(byte, radix: 16)
            desc += " \(hexByte.count == 1 ? "0" : "")\(hexByte)"
        }
        desc += " ]"
        return desc
    }
}
