// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Gamunu Balagalla

import Foundation

public struct ESCLJobInfo: Equatable, Sendable {
    public enum State: String, Sendable { case processing = "Processing", completed = "Completed", canceled = "Canceled", aborted = "Aborted" }

    public var id: Int
    public var uuid: UUID
    public var age: Int
    public var imagesCompleted: Int
    public var imagesToTransfer: Int
    public var state: State

    public init(id: Int, uuid: UUID, age: Int, imagesCompleted: Int, imagesToTransfer: Int, state: State) {
        self.id = id
        self.uuid = uuid
        self.age = age
        self.imagesCompleted = imagesCompleted
        self.imagesToTransfer = imagesToTransfer
        self.state = state
    }

    var reason: String {
        switch state {
        case .processing: return "JobScanning"
        case .completed: return "JobCompletedSuccessfully"
        case .canceled: return "JobCanceledByUser"
        case .aborted: return "AbortedBySystem"
        }
    }
}

public enum ESCLStatus {
    /// `state` is Idle, Processing or Stopped. Every job the agent still remembers is listed.
    public static func xml(state: String, jobs: [ESCLJobInfo]) -> String {
        let list = jobs.isEmpty ? "<scan:Jobs/>" : "<scan:Jobs>" + jobs.map { j in
            "<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(j.id)</pwg:JobUri>"
            + "<pwg:JobUuid>\(j.uuid.uuidString.lowercased())</pwg:JobUuid>"
            + "<scan:Age>\(j.age)</scan:Age>"
            + "<pwg:ImagesCompleted>\(j.imagesCompleted)</pwg:ImagesCompleted>"
            + "<pwg:ImagesToTransfer>\(j.imagesToTransfer)</pwg:ImagesToTransfer>"
            + "<pwg:JobState>\(j.state.rawValue)</pwg:JobState>"
            + "<pwg:JobStateReasons><pwg:JobStateReason>\(j.reason)</pwg:JobStateReason></pwg:JobStateReasons>"
            + "</scan:JobInfo>"
        }.joined() + "</scan:Jobs>"
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        + "<scan:ScannerStatus \(ESCLCaps.ns)>"
        + "<pwg:Version>2.63</pwg:Version><pwg:State>\(state)</pwg:State>\(list)"
        + "</scan:ScannerStatus>"
    }
}
