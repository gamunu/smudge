// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation
import SmudgeCore

let cliArgs = CommandLine.arguments
if let i = cliArgs.firstIndex(of: "--ledm-get") {
    ledmGetAndExit(path: i + 1 < cliArgs.count ? cliArgs[i + 1] : "/DevMgmt/ProductStatusDyn.xml")
} else if cliArgs.contains("--ledm-jobs") {
    ledmJobsAndExit()
} else if let i = cliArgs.firstIndex(of: "--maint") {
    maintJobAndExit(name: i + 1 < cliArgs.count ? cliArgs[i + 1] : "")
} else if let i = cliArgs.firstIndex(of: "--cancel") {
    cancelJobAndExit(id: i + 1 < cliArgs.count ? Int(cliArgs[i + 1]) : nil)
} else if cliArgs.contains("--dump") {
    dumpAndExit()
} else {
    SmudgeApp.main()
}
