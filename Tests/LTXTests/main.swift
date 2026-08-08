import Foundation
@testable import LTXVideoGeneratorCore

let t = TestKit.shared

t.suite("Catalog") {
    t.checkEqual(LTXModelCatalog.resolvedModel(id: nil).id, LTXModelCatalog.defaultModelID, "default model resolves")
    t.checkEqual((1080 / 64) * 64, 1024, "64-px floor")
}

runRegistryTests(t)

t.finish()
