import Foundation
import Hummingbird

struct ModelsHandler {
    static func register(on router: some RouterMethods<some RequestContext>) {
        router.get("/v1/models") { _, _ -> Response in
            let list = OpenAIModelList(object: "list", data: HardcodedModels.all)
            let json = try JSONEncoder().encode(list)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: json))
            )
        }
    }
}
