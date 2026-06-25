// ===----------------------------------------------------------------------===//
//
// This source file is part of the swift-primitives open source project
//
// Copyright (c) 2024-2026 Coen ten Thije Boonkkamp and the swift-primitives project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// ===----------------------------------------------------------------------===//

public import Buffer_Protocol_Primitives

// MARK: - Buffer.Protocol (the typed count surface — ASK-H′ admission)

/// The sole witness is the typed `count` (`Storage.Generational.swift`, the H′ retype);
/// `isEmpty` is the protocol default.
///
/// With the `Store.`Protocol`` conformance this
/// admits the generational store to the family template bound and to `Shared`.
extension Storage.Generational: Buffer.`Protocol` where Allocation: ~Copyable, Element: ~Copyable {}
