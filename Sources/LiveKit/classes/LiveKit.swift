struct LiveKit {
    static func connect(options: ConnectOptions, delegate: RoomDelegate) -> Room {
        let room = Room(name: options.config.roomName)
        room.connect(options: options)
        return room
    }
}
