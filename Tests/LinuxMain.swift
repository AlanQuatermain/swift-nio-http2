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
//
// LinuxMain.swift
//
import XCTest

///
/// NOTE: This file was generated by generate_linux_tests.rb
///
/// Do NOT edit this file directly as it will be regenerated automatically when needed.
///

#if os(Linux) || os(FreeBSD)
   @testable import NIOHPACKTests
   @testable import NIOHTTP2Tests

   XCTMain([
         testCase(BasicTests.allTests),
         testCase(HPACKCodingTests.allTests),
         testCase(HPACKIntegrationTests.allTests),
         testCase(HTTP2FrameParserTests.allTests),
         testCase(HTTP2StreamMultiplexerTests.allTests),
         testCase(HTTP2ToHTTP1CodecTests.allTests),
         testCase(HeaderTableTests.allTests),
         testCase(HuffmanCodingTests.allTests),
         testCase(IntegerCodingTests.allTests),
         testCase(ReentrancyTests.allTests),
         testCase(RingBufferTests.allTests),
         testCase(SimpleClientServerTests.allTests),
    ])
#endif
