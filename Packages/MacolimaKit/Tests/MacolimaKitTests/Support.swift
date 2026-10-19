import Foundation
@testable import MacolimaKit

func container(_ name: String, image: String = "img1", state: ContainerState = .running,
               project: String? = nil, volumes: [String] = []) -> ContainerSummary {
    ContainerSummary(id: "id-\(name)", name: name, image: "x:latest", imageID: image, state: state,
                     status: "", composeProject: project, composeService: nil, volumeNames: volumes)
}

func image(_ id: String, tags: [String] = ["x:latest"], size: Int64 = 100) -> ImageSummary {
    ImageSummary(id: id, tags: tags, size: size)
}

func volume(_ name: String, size: Int64? = 100) -> VolumeSummary {
    VolumeSummary(name: name, size: size)
}
