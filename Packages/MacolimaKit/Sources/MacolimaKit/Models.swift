import Foundation

public enum ContainerState: String, Codable, Sendable {
    case running, exited, paused, restarting, created, dead, removing
}

public struct PortMapping: Codable, Sendable, Hashable, Identifiable {
    public let privatePort: Int
    public let publicPort: Int?
    public let type: String

    public init(privatePort: Int, publicPort: Int?, type: String) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.type = type
    }

    public var id: String { "\(privatePort)/\(type)/\(publicPort.map(String.init) ?? "-")" }
}

public struct ContainerSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let imageID: String
    public let state: ContainerState
    public let status: String
    public let ports: [PortMapping]
    public let composeProject: String?
    public let composeService: String?
    public let volumeNames: [String]
    public let created: Date

    public init(id: String, name: String, image: String, imageID: String, state: ContainerState, status: String,
                ports: [PortMapping] = [], composeProject: String? = nil, composeService: String? = nil,
                volumeNames: [String] = [], created: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.name = name
        self.image = image
        self.imageID = imageID
        self.state = state
        self.status = status
        self.ports = ports
        self.composeProject = composeProject
        self.composeService = composeService
        self.volumeNames = volumeNames
        self.created = created
    }
}

public struct ImageSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// Empty for a dangling image.
    public let tags: [String]
    public let size: Int64
    public let created: Date

    public init(id: String, tags: [String], size: Int64, created: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.tags = tags
        self.size = size
        self.created = created
    }
}

public struct VolumeSummary: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let driver: String
    public let mountpoint: String
    /// `nil` = the engine has not computed the size (reported as -1).
    public let size: Int64?
    public let createdAt: Date?

    public init(name: String, driver: String = "local", mountpoint: String = "", size: Int64?, createdAt: Date? = nil) {
        self.name = name
        self.driver = driver
        self.mountpoint = mountpoint
        self.size = size
        self.createdAt = createdAt
    }

    public var id: String { name }
}
