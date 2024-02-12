/* Copyright Airship and Contributors */

import Combine
import Foundation

/// The Analytics object provides an interface to the Airship Analytics API.
@objc(UAAnalytics)
public final class AirshipAnalytics: NSObject, AirshipComponent, AnalyticsProtocol, @unchecked Sendable {

    /// The shared Analytics instance.
    @objc
    public static var shared: AirshipAnalytics {
        return Airship.analytics
    }

    private static let associatedIdentifiers = "UAAssociatedIdentifiers"
    private static let missingSendID = "MISSING_SEND_ID"
    private static let pushMetadata = "com.urbanairship.metadata"

    /// Screen key for ScreenTracked notification. :nodoc:
    @objc
    public static let screenKey = "screen"

    /// Event key for customEventAdded and regionEventAdded notifications.. :nodoc:
    @objc
    public static let eventKey = "event"

    /// Custom event added notification. :nodoc:
    @objc
    public static let customEventAdded = NSNotification.Name(
        "UACustomEventAdded"
    )

    /// Region event added notification. :nodoc:
    @objc
    public static let regionEventAdded = NSNotification.Name(
        "UARegionEventAdded"
    )
    
    /// FeatureFlag interracted notification. :nodoc:
    @objc
    public static let featureFlagInterracted = NSNotification.Name(
        "UAFeatureFlagInterracted"
    )

    /// Screen tracked notification,. :nodoc:
    @objc
    public static let screenTracked = NSNotification.Name("UAScreenTracked")

    private let config: RuntimeConfig
    private let dataStore: PreferenceDataStore
    private let channel: AirshipChannelProtocol
    private let privacyManager: AirshipPrivacyManager
    private let notificationCenter: AirshipNotificationCenter
    private let date: AirshipDateProtocol
    private let eventManager: EventManagerProtocol
    private let localeManager: AirshipLocaleManagerProtocol
    private let permissionsManager: AirshipPermissionsManager
    private let sessionTracker: SessionTrackerProtocol
    private let serialQueue: AirshipAsyncSerialQueue = AirshipAsyncSerialQueue()

    private let sdkExtensions: Atomic<[String]> = Atomic([])

    // Screen tracking state
    private let screenState: AirshipMainActorValue<ScreenState> = AirshipMainActorValue(ScreenState())
    private let restoreScreenOnForeground: AirshipMainActorValue<String?> = AirshipMainActorValue(nil)

    private let regions: AirshipMainActorValue<Set<String>> = AirshipMainActorValue(Set())


    private var isAirshipReady = false

    /// The conversion send ID. :nodoc:
   @objc
   public var conversionSendID: String? {
       return self.sessionTracker.sessionState.conversionSendID
    }

   /// The conversion push metadata. :nodoc:
   @objc
   public var conversionPushMetadata: String? {
       return self.sessionTracker.sessionState.conversionMetadata
   }

    /// The current session ID.
    @objc
    public var sessionID: String? {
        return self.sessionTracker.sessionState.sessionID
    }

    private let eventSubject = PassthroughSubject<AirshipEventData, Never>()

    /// Airship event publisher
    public var eventPublisher: AnyPublisher<AirshipEventData, Never> {
        eventSubject.eraseToAnyPublisher()
    }


    private var isAnalyticsEnabled: Bool {
        return self.privacyManager.isEnabled(.analytics) &&
        self.config.isAnalyticsEnabled
    }

    @MainActor
    convenience init(
        config: RuntimeConfig,
        dataStore: PreferenceDataStore,
        channel: AirshipChannelProtocol,
        localeManager: AirshipLocaleManagerProtocol,
        privacyManager: AirshipPrivacyManager,
        permissionsManager: AirshipPermissionsManager
    ) {
        self.init(
            config: config,
            dataStore: dataStore,
            channel: channel,
            localeManager: localeManager,
            privacyManager: privacyManager,
            permissionsManager: permissionsManager,
            eventManager: EventManager(
                config: config,
                dataStore: dataStore,
                channel: channel
            )
        )
    }

    @MainActor
    init(
        config: RuntimeConfig,
        dataStore: PreferenceDataStore,
        channel: AirshipChannelProtocol,
        notificationCenter: AirshipNotificationCenter = AirshipNotificationCenter.shared,
        date: AirshipDateProtocol = AirshipDate.shared,
        localeManager: AirshipLocaleManagerProtocol,
        privacyManager: AirshipPrivacyManager,
        permissionsManager: AirshipPermissionsManager,
        eventManager: EventManagerProtocol,
        sessionTracker: SessionTrackerProtocol = SessionTracker(),
        sessionEventFactory: SessionEventFactoryProtocol = SessionEventFactory()
    ) {
        self.config = config
        self.dataStore = dataStore
        self.channel = channel
        self.notificationCenter = notificationCenter
        self.date = date
        self.localeManager = localeManager
        self.privacyManager = privacyManager
        self.permissionsManager = permissionsManager
        self.eventManager = eventManager
        self.sessionTracker = sessionTracker

        super.init()

        self.eventManager.addHeaderProvider {
            await self.makeHeaders()
        }

        self.notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: AppStateTracker.willEnterForegroundNotification,
            object: nil
        )

        self.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: AppStateTracker.didEnterBackgroundNotification,
            object: nil
        )

        self.notificationCenter.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: AppStateTracker.willTerminateNotification,
            object: nil
        )

        self.notificationCenter.addObserver(
            self,
            selector: #selector(updateEnablement),
            name: AirshipPrivacyManager.changeEvent,
            object: nil
        )

        self.notificationCenter.addObserver(
            self,
            selector: #selector(updateEnablement),
            name: AirshipChannel.channelCreatedEvent,
            object: nil
        )


        Task { @MainActor in
            for await event in self.sessionTracker.events {
                self.addEvent(
                    sessionEventFactory.make(event: event),
                    date: event.date,
                    sessionID: event.sessionState.sessionID
                )
            }
        }
    }

    @objc
    @MainActor
    private func applicationWillEnterForeground() {
        // Start tracking previous screen before backgrounding began
        if let previousScreen = self.restoreScreenOnForeground.value,
           self.screenState.value.current == nil
        {
            trackScreen(previousScreen)
        }
        self.restoreScreenOnForeground.set(nil)
    }

    @objc
    @MainActor
    private func applicationDidEnterBackground() {
        self.restoreScreenOnForeground.set(self.screenState.value.current)
        self.trackScreen(nil)
    }

    @objc
    @MainActor
    private func applicationWillTerminate() {
        self.trackScreen(nil)
    }


    // MARK: -
    // MARK: Analytics Headers

    /// :nodoc:
    @MainActor
    public func addHeaderProvider(
        _ headerProvider: @Sendable @escaping () async -> [String: String]
    ) {
        self.eventManager.addHeaderProvider(headerProvider)
    }

    private func makeHeaders() async -> [String: String] {
        var headers: [String: String] = [:]

        // Device info
        #if !os(watchOS)
        headers["X-UA-Device-Family"] = await UIDevice.current.systemName
        headers["X-UA-OS-Version"] = await UIDevice.current.systemVersion
        #else
        headers["X-UA-Device-Family"] =
            WKInterfaceDevice.current().systemName
        headers["X-UA-OS-Version"] =
            WKInterfaceDevice.current().systemVersion
        #endif

        headers["X-UA-Device-Model"] = AirshipUtils.deviceModelName()

        // App info
        if let infoDictionary = Bundle.main.infoDictionary {
            headers["X-UA-Package-Name"] =
                infoDictionary[kCFBundleIdentifierKey as String] as? String
        }

        headers["X-UA-Package-Version"] = AirshipUtils.bundleShortVersionString() ?? ""

        // Time zone
        let currentLocale = self.localeManager.currentLocale
        headers["X-UA-Timezone"] = NSTimeZone.default.identifier
        headers["X-UA-Locale-Language"] = currentLocale.getLanguageCode()
        headers["X-UA-Locale-Country"] = currentLocale.getRegionCode()
        headers["X-UA-Locale-Variant"] = currentLocale.getVariantCode()

        // Airship identifiers
        headers["X-UA-Channel-ID"] = self.channel.identifier
        headers["X-UA-App-Key"] = self.config.appKey

        // SDK Version
        headers["X-UA-Lib-Version"] = AirshipVersion.version

        // SDK Extensions
        let extensions = self.sdkExtensions.value
        if extensions.count > 0 {
            headers["X-UA-Frameworks"] = extensions.joined(
                separator: ", "
            )
        }

        // Permissions
        for permission in self.permissionsManager.configuredPermissions {
            let status = await self.permissionsManager.checkPermissionStatus(permission)
            headers["X-UA-Permission-\(permission.stringValue)"] = status.stringValue
        }

        return headers
    }

    /// Triggers an analytics event.
    /// - Parameter event: The event to be triggered
    @objc
    public func addEvent(_ event: AirshipEvent) {
        self.addEvent(
            event,
            date: self.date.now,
            sessionID: self.sessionTracker.sessionState.sessionID
        )
    }

    private func addEvent(_ event: AirshipEvent, date: Date, sessionID: String) {
        guard self.isAnalyticsEnabled else {
            AirshipLogger.trace(
                "Analytics disabled, ignoring event: \(event.eventType)"
            )
            return
        }

        guard
            event.isValid?() != false,
            let body = try? AirshipJSON.wrap(event.data as? [String: Any])
        else {
            AirshipLogger.error("Dropping invalid event: \(event)")
            return
        }
        
        let eventData = AirshipEventData(
            body: body,
            id: NSUUID().uuidString,
            date: date,
            sessionID: sessionID,
            type: event.eventType
        )

        if let customEvent = event as? CustomEvent {
            self.notificationCenter.post(
                name: AirshipAnalytics.customEventAdded,
                object: self,
                userInfo: [AirshipAnalytics.eventKey: customEvent]
            )
        }

        if let regionEvent = event as? RegionEvent {
            let shouldInsert: Bool = regionEvent.boundaryEvent == .enter
            let regionID = regionEvent.regionID

            Task { @MainActor in
                self.regions.update { regions in
                    if (shouldInsert) {
                        regions.insert(regionID)
                    } else {
                        regions.remove(regionID)
                    }
                }
            }

            self.notificationCenter.post(
                name: AirshipAnalytics.regionEventAdded,
                object: self,
                userInfo: [AirshipAnalytics.eventKey: regionEvent]
            )
        }

        self.serialQueue.enqueue {
            guard self.isAnalyticsEnabled else {
                return
            }

            do {
                AirshipLogger.debug("Adding event with type \(eventData.type)")
                AirshipLogger.trace("Adding event \(eventData)")
                try await self.eventManager.addEvent(eventData)
                self.eventSubject.send(eventData)
                await self.eventManager.scheduleUpload(
                    eventPriority: event.priority
                )
            } catch {
                AirshipLogger.error("Failed to save event \(error)")
                return
            }
        }
    }

    /// Associates identifiers with the device. This call will add a special event
    /// that will be batched and sent up with our other analytics events. Previous
    /// associated identifiers will be replaced.
    ///
    /// For internal use only. :nodoc:
    ///
    /// - Parameter associatedIdentifiers: The associated identifiers.
    @objc
    public func associateDeviceIdentifiers(
        _ associatedIdentifiers: AssociatedIdentifiers
    ) {
        guard self.isAnalyticsEnabled else {
            AirshipLogger.warn(
                "Unable to associate identifiers \(associatedIdentifiers.allIDs) when analytics is disabled"
            )
            return
        }

        if let previous = self.dataStore.object(
            forKey: AirshipAnalytics.associatedIdentifiers
        ) as? [String: String] {
            if previous == associatedIdentifiers.allIDs {
                AirshipLogger.info(
                    "Skipping analytics event addition for duplicate associated identifiers."
                )
                return
            }
        }

        self.dataStore.setObject(
            associatedIdentifiers.allIDs,
            forKey: AirshipAnalytics.associatedIdentifiers
        )

        if let event = AssociateIdentifiersEvent(
            identifiers: associatedIdentifiers
        ) {
            self.addEvent(event)
        }
    }

    /// The device's current associated identifiers.
    /// - Returns: The device's current associated identifiers.
    @objc
    public func currentAssociatedDeviceIdentifiers() -> AssociatedIdentifiers {
        let storedIDs =
            self.dataStore.object(forKey: AirshipAnalytics.associatedIdentifiers)
            as? [String: String]
        return AssociatedIdentifiers(
            dictionary: storedIDs != nil ? storedIDs : [:]
        )
    }

    /// Initiates screen tracking for a specific app screen, must be called once per tracked screen.
    /// - Parameter screen: The screen's identifier.
    @objc
    @MainActor
    public func trackScreen(_ screen: String?) {
        let date = self.date.now
        // Prevent duplicate calls to track same screen
        guard screen != self.screenState.value.current else {
            return
        }

        self.notificationCenter.post(
            name: AirshipAnalytics.screenTracked,
            object: self,
            userInfo: screen == nil ? [:] : [AirshipAnalytics.screenKey: screen!]
        )


        let currentScreen = self.screenState.value.current
        let screenStartDate = self.screenState.value.startDate
        let previousScreen = self.screenState.value.previous

        self.screenState.update { state in
            state.current = screen
            state.startDate = date
            state.previous = currentScreen
        }

        // If there's a screen currently being tracked set it's stop time and add it to analytics
        if let currentScreen = currentScreen, let screenStartDate = screenStartDate {

            guard
                let ste = ScreenTrackingEvent(
                    screen: currentScreen,
                    previousScreen: previousScreen,
                    startDate: screenStartDate,
                    duration: date.timeIntervalSince(screenStartDate)
                )
            else {
                AirshipLogger.error(
                    "Unable to create screen tracking event"
                )
                return
            }

            // Add screen tracking event to next analytics batch
            self.addEvent(ste)
        }
    }

    /// Registers an SDK extension with the analytics module.
    /// For internal use only. :nodoc:
    ///
    ///  - Parameters:
    ///   - ext: The SDK extension.
    ///   - version: The version.
    @objc
    public func registerSDKExtension(
        _ ext: AirshipSDKExtension,
        version: String
    ) {
        let sanitizedVersion = version.replacingOccurrences(of: ",", with: "")
        self.sdkExtensions.value.append("\(ext.name):\(sanitizedVersion)")
    }

    @objc
    private func updateEnablement() {
        guard self.isAnalyticsEnabled else {
            self.eventManager.uploadsEnabled = false
            Task {
                do {
                    try await self.eventManager.deleteEvents()
                } catch {
                    AirshipLogger.error("Failed to delete events \(error)")
                }
            }
            return
        }

        let uploadsEnabled = self.isAirshipReady && self.channel.identifier != nil


        if (self.eventManager.uploadsEnabled != uploadsEnabled) {
            self.eventManager.uploadsEnabled = uploadsEnabled

            if (uploadsEnabled) {
                Task {
                    await self.eventManager.scheduleUpload(
                        eventPriority: .normal
                    )
                }
            }
        }
    }


    @MainActor
    public func airshipReady() {
        self.isAirshipReady = true
        self.updateEnablement()

        self.sessionTracker.airshipReady()
    }
}

extension AirshipAnalytics: InternalAnalyticsProtocol {
    @MainActor
    public var currentScreen: String? {
        return self.screenState.value.current
    }
    
    @MainActor
    public var regionUpdates: AsyncStream<Set<String>> {
        return self.regions.updates
    }
    
    @MainActor
    public var currentRegions: Set<String> {
        return self.regions.value
    }

    @MainActor
    public var screenUpdates: AsyncStream<String?> {
        return AsyncStream { [screenState] continutation in
            let updates = screenState.updates
            let task = Task {
                for await value in updates {
                    continutation.yield(value.current)
                }
            }

            continutation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Called to notify analytics the app was launched from a push notification.
    /// For internal use only. :nodoc:
    /// - Parameter notification: The push notification.
    @MainActor
    public func launched(fromNotification notification: [AnyHashable: Any]) {
        if AirshipUtils.isAlertingPush(notification) {
            let sendID = notification["_"] as? String
            let metadata = notification[AirshipAnalytics.pushMetadata] as? String

            self.sessionTracker.launchedFromPush(
                sendID: sendID ?? AirshipAnalytics.missingSendID,
                metadata: metadata
            )
        }
    }

    public func onDeviceRegistration(token: String) {
        guard privacyManager.isEnabled(.push) else {
            return
        }

        addEvent(
            DeviceRegistrationEvent(
                channelID: self.channel.identifier,
                deviceToken: token
            )
        )
    }

    @available(tvOS, unavailable)
    @MainActor
    public func onNotificationResponse(
        response: UNNotificationResponse,
        action: UNNotificationAction?
    ) {
        let userInfo = response.notification.request.content.userInfo

        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            self.launched(fromNotification: userInfo)
        } else if let action = action {
            let categoryID = response.notification.request.content
                .categoryIdentifier
            let responseText = (response as? UNTextInputNotificationResponse)?
                .userText

            if action.options.contains(.foreground) == true {
                self.launched(fromNotification: userInfo)
            }

            addEvent(
                InteractiveNotificationEvent(
                    action: action,
                    category: categoryID,
                    notification: userInfo,
                    responseText: responseText
                )
            )
        }
    }
}


protocol SessionEventFactoryProtocol: Sendable {
    @MainActor
    func make(event: SessionEvent) -> AirshipEvent
}

struct SessionEventFactory: SessionEventFactoryProtocol {
    @MainActor
    func make(event: SessionEvent) -> AirshipEvent {
        switch (event.type) {
        case .foregroundInit:
            return AppInitEvent(isForeground: true, sessionState: event.sessionState)
        case .backgroundInit:
            return AppInitEvent(isForeground: false, sessionState: event.sessionState)
        case .background:
            return AppBackgroundEvent(sessionState: event.sessionState)
        case .foreground:
            return AppForegroundEvent(sessionState: event.sessionState)
        }
    }
}

fileprivate struct ScreenState {
    var current: String?
    var previous: String?
    var startDate: Date?
}
