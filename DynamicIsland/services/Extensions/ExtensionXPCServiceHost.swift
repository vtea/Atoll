/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Foundation
import Security
import AtollExtensionKit

/// Shared constants for the Atoll extension XPC service.
enum ExtensionXPCServiceConstants {
    static let machServiceName = "com.ebullioscopic.Atoll.xpc"
}

@MainActor
final class ExtensionXPCServiceHost: NSObject, NSXPCListenerDelegate {
    static let shared = ExtensionXPCServiceHost()

    private final class ClientContext {
        weak var connection: NSXPCConnection?
        let bundleIdentifier: String

        init(connection: NSXPCConnection, bundleIdentifier: String) {
            self.connection = connection
            self.bundleIdentifier = bundleIdentifier
        }
    }

    private var listener: NSXPCListener?
    private var clientContexts: [ObjectIdentifier: ClientContext] = [:]

    func start() {
        guard listener == nil else { return }

        // NSXPCListener(machServiceName:) is killed unless mach-services is
        // present and actually granted. Ad-hoc and unsigned signatures can
        // still carry the entitlement blob; SecTask reports that blob, and
        // amfid kills the process anyway. Only a team-signed binary may listen.
        if AppRuntimeEnvironment.isUITesting || !canHostMachService {
            Logger.log("Bypassing Atoll XPC listener without a granted mach-services entitlement", category: .extensions)
            return
        }

        let listener = NSXPCListener(machServiceName: ExtensionXPCServiceConstants.machServiceName)
        listener.delegate = self
        self.listener = listener
        listener.resume()

        Logger.log("Started Atoll XPC listener", category: .extensions)
    }

    private var canHostMachService: Bool {
        hasMachServicesEntitlement && signatureGrantsRestrictedEntitlements
    }

    private var hasMachServicesEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        var error: Unmanaged<CFError>?
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.mach-services" as CFString,
            &error
        )
        if let error {
            _ = error.takeRetainedValue()
            return false
        }
        return value != nil
    }

    /// Team-signed Developer ID and Apple Development builds grant restricted
    /// entitlements. Ad-hoc signatures set `kSecCodeSignatureAdhoc` and do not.
    private var signatureGrantsRestrictedEntitlements: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }

        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess, let info = info as? [String: Any] else { return false }

        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return false }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return false
        }
        return true
    }

    func stop() {
        listener?.invalidate()
        listener = nil
        clientContexts.removeAll()
        Logger.log("Stopped Atoll XPC listener", category: .extensions)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let bundleIdentifier = resolveBundleIdentifier(for: connection) else {
            Logger.log("Rejected XPC connection without bundle identifier", category: .extensions)
            return false
        }

        let service = ExtensionXPCService(bundleIdentifier: bundleIdentifier, host: self, connection: connection)
        connection.exportedInterface = NSXPCInterface(with: AtollXPCServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: AtollXPCClientProtocol.self)

        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                self?.removeConnection(connection)
            }
        }

        connection.resume()
        clientContexts[ObjectIdentifier(connection)] = ClientContext(connection: connection, bundleIdentifier: bundleIdentifier)
        Logger.log("Accepted XPC connection from \(bundleIdentifier)", category: .extensions)
        return true
    }

    func notifyAuthorizationChange(bundleIdentifier: String, isAuthorized: Bool) {
        deliver(to: bundleIdentifier) { client in
            client.authorizationDidChange(isAuthorized: isAuthorized)
        }
    }

    func notifyActivityDismiss(bundleIdentifier: String, activityID: String) {
        deliver(to: bundleIdentifier) { client in
            client.activityDidDismiss(activityID: activityID)
        }
    }

    func notifyWidgetDismiss(bundleIdentifier: String, widgetID: String) {
        deliver(to: bundleIdentifier) { client in
            client.widgetDidDismiss(widgetID: widgetID)
        }
    }

    func notifyNotchExperienceDismiss(bundleIdentifier: String, experienceID: String) {
        deliver(to: bundleIdentifier) { client in
            client.notchExperienceDidDismiss(experienceID: experienceID)
        }
    }

    private func resolveBundleIdentifier(for connection: NSXPCConnection) -> String? {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier != 0 else { return nil }

        if let app = NSRunningApplication(processIdentifier: pid_t(processIdentifier)),
           let bundleIdentifier = app.bundleIdentifier {
            return bundleIdentifier
        }

        return nil
    }

    private func deliver(to bundleIdentifier: String, send block: (AtollXPCClientProtocol) -> Void) {
        var staleIdentifiers: [ObjectIdentifier] = []

        for (identifier, context) in clientContexts where context.bundleIdentifier == bundleIdentifier {
            guard let connection = context.connection else {
                staleIdentifiers.append(identifier)
                continue
            }

            guard let client = connection.remoteObjectProxyWithErrorHandler({ error in
                Logger.log("Failed to deliver XPC callback to \(bundleIdentifier): \(error)", category: .extensions)
            }) as? AtollXPCClientProtocol else {
                continue
            }

            block(client)
        }

        staleIdentifiers.forEach { clientContexts.removeValue(forKey: $0) }
    }

    private func removeConnection(_ connection: NSXPCConnection) {
        clientContexts.removeValue(forKey: ObjectIdentifier(connection))
        Logger.log("Removed XPC connection", category: .extensions)
    }
}
