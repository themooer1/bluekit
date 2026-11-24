//
//  BlueKit.swift
//  BlueKit
//
//  A thin Swift umbrella over the prebuilt XCFrameworks. Importing `BlueKit`
//  re-exports the C modules `LibBluray`, `LibAACS` and `LibBDPlus`, so the
//  upstream C APIs (`bd_open`, `bd_get_version`, ...) are available directly.
//
//  BlueKit is a general-purpose library for reading, navigating and interacting
//  with Blu-ray discs on macOS.
//
//  No AACS keys are distributed with this package.
//

@_exported import LibBluray
@_exported import LibAACS
@_exported import LibBDPlus
