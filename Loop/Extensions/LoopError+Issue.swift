//
//  LoopError+Issue.swift
//  Loop
//
//  Created by B.3.a refactor on 2026-04-25.
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Extends LoopError (now in LoopAlgorithmCore) with the app-only
//  `var issue: StoredDosingDecision.Issue` property and helpers that depend
//  on StoredDosingDecisionIssue (defined in Loop/Extensions/DosingDecisionStore.swift).
//

import Foundation
import LoopKit
import LoopAlgorithmCore

extension LoopError {
    var issue: StoredDosingDecision.Issue {
        return StoredDosingDecision.Issue(id: issueId, details: issueDetails)
    }

    var issueId: String {
        switch self {
        case .configurationError:
            return "configurationError"
        case .connectionError:
            return "connectionError"
        case .missingDataError:
            return "missingDataError"
        case .glucoseTooOld:
            return "glucoseTooOld"
        case .invalidFutureGlucose:
            return "invalidFutureGlucose"
        case .pumpDataTooOld:
            return "pumpDataTooOld"
        case .recommendationExpired:
            return "recommendationExpired"
        case .pumpSuspended:
            return "pumpSuspended"
        case .pumpManagerError:
            return "pumpManagerError"
        case .unknownError:
            return "unknownError"
        }
    }

    var issueDetails: [String: String] {
        var details: [String: String] = [:]
        switch self {
        case .configurationError(let detail):
            details["detail"] = detail.rawValue
        case .missingDataError(let detail):
            details["detail"] = detail.rawValue
        case .glucoseTooOld(let date):
            details["date"] = StoredDosingDecisionIssue.description(for: date)
        case .invalidFutureGlucose(let date):
            details["date"] = StoredDosingDecisionIssue.description(for: date)
        case .pumpDataTooOld(let date):
            details["date"] = StoredDosingDecisionIssue.description(for: date)
        case .recommendationExpired(let date):
            details["date"] = StoredDosingDecisionIssue.description(for: date)
        case .pumpManagerError(let pumpManagerError):
            details = pumpManagerError.issueDetails
        case .unknownError(let error):
            details["error"] = StoredDosingDecisionIssue.description(for: error)
        default:
            break
        }
        return details
    }
}
