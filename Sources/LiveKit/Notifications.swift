//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/07.
//

import WebRTC
import UIKit
import Promises

//
// Used for internal notifications
// Type-safe
//

//protocol Observer {
//    //
//}
//
//class Observable<X: AnyObject> where X : Observer {
//
//    let listeners = NSHashTable<X>.weakObjects()
//
//    func addObserver(_ observer: X) {
//        listeners.add(observer)
//    }
//
//    func removeObserver(_ observer: X) {
//        listeners.remove(observer)
//    }
//}

typealias EventFilter<E: Event> = (E) -> Bool

extension NotificationCenter {

    internal static let liveKit = NotificationCenter()
    static let eventKey = "event"

    // 1 time listen for event
    func wait<E: Event>(for event: E.Type, timeout: TimeInterval, filter: EventFilter<E>? = nil) -> Promise<E> {
        let p = Promise<E>.pending()
        var t: NSObjectProtocol?

        // did time out
        let timer = DispatchWorkItem() { [weak self] in
            self?.removeObserver(t!)
            p.reject(InternalError.timeout())
        }

        let defaultFnc: (E) -> Void = { [weak self] e in
            timer.cancel() // stop timer
            self?.removeObserver(t!)
            p.fulfill(e)
        }

        var useFunc = defaultFnc

        if let filter = filter {
            useFunc = { filter($0) ? defaultFnc($0) : () }
        }

        t = listen(for: event, using: useFunc)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
                                      execute: timer)

        return p
    }

    func listen<E: Event>(for event: E.Type, using block: @escaping (E) -> ()) -> NSObjectProtocol {
        addObserver(forName: event.name, object: nil, queue: nil, using: { note in
            guard let event = note.userInfo?[NotificationCenter.eventKey] as? E else {
                logger.debug("Failed to get event object from notification")
                return
            }
            block(event)
        })
//        return ListenToken(token: t, center: self)
    }

    func send<E: Event>(event: E) {
        post(name: E.name, object: event, userInfo: [NotificationCenter.eventKey: event])
    }
}

//class ListenToken {
//    let token: NSObjectProtocol
//    let center: NotificationCenter
//
//    init(token: NSObjectProtocol, center: NotificationCenter) {
//        self.token = token
//        self.center = center
//    }
//
//    deinit {
//        center.removeObserver(token)
//    }
//}

protocol Event {
    static var name: Notification.Name { get }
}

// MARK: - Events

struct IceStateUpdatedEvent: Event {
    static let name = Notification.Name("livekit.iceStateUpdated")
    let target: Livekit_SignalTarget
    let primary: Bool
    let iceState: RTCIceConnectionState
}

struct IceCandidateEvent: Event {
    static let name = Notification.Name("livekit.iceCandidate")
    let target: Livekit_SignalTarget
    let primary: Bool
    let iceCandidate: RTCIceCandidate
}

struct ShouldNegotiateEvent: Event {
    static let name = Notification.Name("livekit.shouldNegotiate")
    let target: Livekit_SignalTarget
    let primary: Bool
}

struct ReceivedTrackEvent: Event {
    static let name = Notification.Name("livekit.receivedTrack")
    let target: Livekit_SignalTarget
    let primary: Bool
    let track: RTCMediaStreamTrack
    let streams: [RTCMediaStream]
}

struct DataChannelEvent: Event {
    static let name = Notification.Name("livekit.dataChannel")
    let target: Livekit_SignalTarget
    let primary: Bool
    let dataChannel: RTCDataChannel
}
