//
//  WatchAPNsRegistration.swift
//  WatchApp Extension
//
//  Pure helper extracted from ExtensionDelegate.didRegisterForRemoteNotifications
//  so the persist-and-publish behavior is unit-testable without a live
//  WKExtension. Production callsite (ExtensionDelegate) injects the live
//  transport + store; tests inject fakes.
//

import Foundation
import OmniBLE

enum WatchAPNsRegistration {
    /// Handle a `didRegisterForRemoteNotifications` payload: build the
    /// publication record, persist locally, queue for the phone.
    static func handleDidRegister(
        deviceToken: Data,
        transport: PhoneWatchTransportQueueing?,
        store: APNsTokenStore,
        now: () -> Date = Date.init
    ) {
        let publication = APNsTokenPublication(
            protocolVersion: PhoneWatchProtocol.currentVersion,
            sentAt: now(),
            role: .watch,
            token: deviceToken,
            expiresAt: now().addingTimeInterval(60 * 60 * 24 * 30)
        )
        store.save(publication)
        transport?.queueMessage(.apnsTokenPublish(publication))
    }
}
