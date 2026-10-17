#!/usr/bin/env swift
import Foundation

// Retired on 2026-10-03. The approved gold candidates are packaged by
// scripts/package-clown-gold.py; this entry point remains so old invocations
// fail clearly instead of producing an incompatible 12-frame ride.
FileHandle.standardError.write(Data("package-clown-ride.swift is retired; run scripts/package-clown-gold.py\n".utf8))
exit(1)
