import Foundation

enum ActivityType: Int {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case custom = 4
    case competing = 5
}

enum PresenceStatus: String {
    case online
    case idle
    case dnd
}

struct ActivityPayload: Equatable {
    var name: String = ""
    var type: Int
    var details: String?
    var state: String?
    var largeImage: String?
    var largeText: String?
    var smallImage: String?
    var smallText: String?
    var startMs: Int64?
    var endMs: Int64?
    var buttons: [(String, String)] = []

    static func == (lhs: ActivityPayload, rhs: ActivityPayload) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type && lhs.details == rhs.details
            && lhs.state == rhs.state && lhs.largeImage == rhs.largeImage
            && lhs.largeText == rhs.largeText && lhs.smallImage == rhs.smallImage
            && lhs.smallText == rhs.smallText && lhs.startMs == rhs.startMs
            && lhs.endMs == rhs.endMs
            && lhs.buttons.elementsEqual(rhs.buttons, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }
}

enum DiscordPresence {
    // swiftlint:disable:next function_parameter_count
    static func buildActivity(
        name: String,
        type: ActivityType,
        details: String?,
        state: String?,
        largeImage: String?,
        largeText: String?,
        smallImage: String?,
        smallText: String?,
        startMs: Int64?,
        endMs: Int64?,
        buttons: [(String, String)]
    ) -> ActivityPayload {
        ActivityPayload(
            name: name,
            type: type.rawValue,
            details: details,
            state: state,
            largeImage: largeImage,
            largeText: largeText,
            smallImage: smallImage,
            smallText: smallText,
            startMs: startMs,
            endMs: endMs,
            buttons: buttons
        )
    }
}
