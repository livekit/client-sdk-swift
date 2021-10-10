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

//typealias EventFilter<E: Event> = (E) -> Bool
//
//extension NotificationCenter {
//
//    internal static let liveKit = NotificationCenter()
//    static let eventKey = "event"
//
//    // 1 time listen for event
//    func wait<E: Event>(for event: E.Type, timeout: TimeInterval, filter: EventFilter<E>? = nil) -> Promise<E> {
//        let p = Promise<E>.pending()
//        var t: NSObjectProtocol?
//
//        // did time out
//        let timer = DispatchWorkItem() { [weak self] in
//            self?.removeObserver(t!)
//            p.reject(InternalError.timeout())
//        }
//
//        let defaultFnc: (E) -> Void = { [weak self] e in
//            timer.cancel() // stop timer
//            self?.removeObserver(t!)
//            p.fulfill(e)
//        }
//
//        var useFunc = defaultFnc
//
//        if let filter = filter {
//            useFunc = { filter($0) ? defaultFnc($0) : () }
//        }
//
//        t = listen(for: event, using: useFunc)
//
//        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
//                                      execute: timer)
//
//        return p
//    }
//
//    func listen<E: Event>(for event: E.Type, using block: @escaping (E) -> ()) -> NSObjectProtocol {
//        addObserver(forName: event.name, object: nil, queue: nil, using: { note in
//            guard let event = note.userInfo?[NotificationCenter.eventKey] as? E else {
//                logger.debug("Failed to get event object from notification")
//                return
//            }
//            block(event)
//        })
////        return ListenToken(token: t, center: self)
//    }
//
//    func send<E: Event>(event: E) {
//        post(name: E.name, object: event, userInfo: [NotificationCenter.eventKey: event])
//    }
//}

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

//protocol Event {
//    static var name: Notification.Name { get }
//}

// MARK: - Events

//struct IceStateUpdatedEvent: Event {
//    static let name = Notification.Name("livekit.iceStateUpdated")
//    let target: Livekit_SignalTarget
//    let primary: Bool
//    let iceState: RTCIceConnectionState
//}
//
//struct IceCandidateEvent: Event {
//    static let name = Notification.Name("livekit.iceCandidate")
//    let target: Livekit_SignalTarget
//    let primary: Bool
//    let iceCandidate: RTCIceCandidate
//}
//
//struct ShouldNegotiateEvent: Event {
//    static let name = Notification.Name("livekit.shouldNegotiate")
//    let target: Livekit_SignalTarget
//    let primary: Bool
//}
//
//struct ReceivedTrackEvent: Event {
//    static let name = Notification.Name("livekit.receivedTrack")
//    let target: Livekit_SignalTarget
//    let primary: Bool
//    let track: RTCMediaStreamTrack
//    let streams: [RTCMediaStream]
//}
//
//struct DataChannelEvent: Event {
//    static let name = Notification.Name("livekit.dataChannel")
//    let target: Livekit_SignalTarget
//    let primary: Bool
//    let dataChannel: RTCDataChannel
//}



//class WeakElement<T:  Hashable>: Hashable {
//    // Keep weak element
//    weak var e: AnyObject?
//
//    init(_ e: T) {
//        self.e = e
//    }
//
//    // MARK: Hashable
//
//    static func == (lhs: WeakElement<T>, rhs: WeakElement<T>) -> Bool {
//        lhs.e == rhs.e
//    }
//
//    func hash(into hasher: inout Hasher) {
//        hasher.combine(e)
//    }
//}
//
//private var set = Set<WeakElement<RTCEngineDelegate>>()


//class WeakSet<T: AnyObject & Hashable> {
//
//
//
//
//    @inlinable public func add(_ e: T) {
//        set.insert(WeakElement(e))
//    }
//
//    public func remove(_ e: T) {
//        set.remove(e as! WeakElement)
//    }
//}


//func x2() {
//    //
//}
//final class WeakServiceDelegate<T: AnyObject> {
//    private(set) weak var value: T?
//    init(value: T?) {
//        self.value = value
//    }
//}
//
//protocol SomeContainer: AnyObject { }
//extension WeakReference: SomeContainer { }
//
//private var observers = [SomeContainer]()
//


protocol MulticastDelegate {
    associatedtype DelegateType
    var delegates: NSHashTable<AnyObject> { get }
}

extension MulticastDelegate {

    func add(delegate: DelegateType) {
        delegates.add(delegate as AnyObject)
    }

    func remove(delegate: DelegateType) {
        delegates.remove(delegate as AnyObject)
    }

    internal func notify(_ fnc: (DelegateType) -> Void) {
        for d in delegates.objectEnumerator() {
            if let d = d as? DelegateType { fnc(d) }
        }
    }
}

extension Array where Element: MulticastDelegate {

    func wait(timeout: TimeInterval,
                  onTimeout: Error = InternalError.timeout(),
                  builder: (@escaping () -> Void) -> Element.DelegateType) -> Promise<Void> {

        //        let onDelegates = self.compactMap { $0 }
        //        guard !onDelegates.isEmpty else {
        //            return Promise(InternalError.state(""))
        //        }

        let promise = Promise<Void>.pending()
        var timer: DispatchWorkItem?
        var delegate: Element.DelegateType?

        let fulfill = { [weak promise] in
            // cancel timer
            timer?.cancel()

            // stop listening
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.fulfill(())
        }

        let reject = { [weak promise] in
            // stop listening
            for multicast in self {
                multicast.remove(delegate: delegate!)
            }

            promise?.reject(onTimeout)
        }

        delegate = builder(fulfill)


        // start listening
        for multicast in self {
            multicast.add(delegate: delegate!)
        }

        // start timer
        timer = DispatchWorkItem() { reject() }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout,
                                      execute: timer!)

        return promise
    }
}
