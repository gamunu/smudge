// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeKit
import SmudgeScan

setvbuf(stderr, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--probe") {
    runProbe(value: value, flag: { args.contains($0) })
} else if args.contains("--probe-bonjour") {
    runProbeBonjour()
} else if args.contains("--serve") {
    runServe(serial: value("--serial"), demo: args.contains("--demo"), demoDelay: Double(value("--delay") ?? "") ?? 1)
} else if args.isEmpty {
    Agent().run()
} else {
    FileHandle.standardError.write(Data("usage: smudge-scand [--serve [--serial S] [--demo] | --probe [--serial S] [--res N] [--format Jpeg|Raw] [--color Color|Gray] --out DIR\n".utf8))
    exit(2)
}
