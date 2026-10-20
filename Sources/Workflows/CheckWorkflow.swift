import Core
import Foundation
import Managers
import Terminal

package enum CheckWorkflowError: LocalizedError, Sendable {
  case securityViolation
  case checkFailed
}

/// Interactive CLI workflow to execute invariant checks and format report outputs.
package enum CheckWorkflow {
  /// Executes the invariant check pipeline, formats output, and returns whether all active rules passed.
  package static func execute(json: Bool) async throws -> Bool {
    let report: CheckReport
    do {
      report = try await CheckManager.runPipeline()
    } catch let regErr as RegistryError {
      switch regErr {
      case .signatureInvalid(let msg):
        Terminal.error("invariants check: signature invalid — \(msg)")
        throw CheckWorkflowError.securityViolation
      case .signatureNotFound(let url):
        Terminal.error("invariants check: signature not found at \(url.path)")
        throw CheckWorkflowError.securityViolation
      case .engineVersionMismatch(let req, let inst):
        Terminal.error("invariants check: engine version mismatch (installed \(inst), requires \(req))")
        throw CheckWorkflowError.securityViolation
      default:
        Terminal.error("invariants check: \(regErr)")
        throw CheckWorkflowError.checkFailed
      }
    } catch let floorErr as FloorError {
      switch floorErr {
      case .unauthorizedSigner(let v, let pv):
        Terminal.error(
          "invariants floor check failed: Version \(v) is not signed by an authorized signer from parent version \(pv)."
        )
        throw CheckWorkflowError.securityViolation
      default:
        Terminal.error("invariants floor check failed: \(floorErr)")
        throw CheckWorkflowError.checkFailed
      }
    } catch {
      Terminal.error("invariants check: \(error.localizedDescription)")
      throw CheckWorkflowError.checkFailed
    }

    if json {
      FileHandle.standardOutput.write(Data(ReportFormatter.formatJSON(report).utf8))
    } else {
      FileHandle.standardOutput.write(Data(ReportFormatter.formatText(report).utf8))
    }

    return !report.hasProblems
  }
}
