import CoreLocation
import Flutter
import UIKit

/// Wakes the background worker when the device enters a user-defined region (e.g. home).
///
/// Region monitoring is one of the few iOS mechanisms that relaunches the app even after the
/// user swiped it away in the app switcher, which makes it a far more dependable trigger than
/// BGTaskScheduler alone. On entry we get roughly 30 seconds of background execution, which is
/// enough to sync and start uploads; we also ask iOS for a processing task slot so the remaining
/// work can continue as soon as the system allows.
class GeofenceTrigger: NSObject, CLLocationManagerDelegate {
  static let shared = GeofenceTrigger()

  private static let channelName = "app.immich/geofence"
  private static let regionIdentifier = "app.immich.geofence.home"
  private static let defaultsKey = "immich.geofence.home"
  private static let defaultRadius: CLLocationDistance = 150
  private static let workerBudgetSeconds = 25

  private let manager = CLLocationManager()
  private var pendingSetHome: FlutterResult?
  private var pendingRadius: CLLocationDistance = defaultRadius

  private override init() {
    super.init()
    manager.delegate = self
  }

  // MARK: - Lifecycle

  /// Must be called on every launch, including launches the system performs for a region event,
  /// so that the delegate is in place before CoreLocation delivers the callback.
  func start() {
    guard let region = storedRegion() else { return }
    if manager.authorizationStatus == .authorizedAlways {
      manager.startMonitoring(for: region)
      print("GeofenceTrigger: monitoring \(region.center.latitude),\(region.center.longitude) r=\(region.radius)")
    }
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: GeofenceTrigger.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
        case "getStatus":
          result(self.status())
        case "setHomeToCurrentLocation":
          let args = call.arguments as? [String: Any]
          self.setHomeToCurrentLocation(radius: args?["radius"] as? Double, result: result)
        case "disable":
          self.disable()
          result(self.status())
        case "triggerNow":
          // Give the user a few seconds to send the app to the background first
          DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.runWorker(reason: "manual")
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Channel handlers

  private func status() -> [String: Any] {
    var dict: [String: Any] = [
      "enabled": storedRegion() != nil,
      "authorization": authorizationName(manager.authorizationStatus),
      "monitoringAvailable": CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
    ]
    if let region = storedRegion() {
      dict["latitude"] = region.center.latitude
      dict["longitude"] = region.center.longitude
      dict["radius"] = region.radius
    }
    return dict
  }

  private func setHomeToCurrentLocation(radius: Double?, result: @escaping FlutterResult) {
    guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
      return result(FlutterError(code: "unavailable", message: "Region monitoring is not available", details: nil))
    }
    if pendingSetHome != nil {
      return result(FlutterError(code: "busy", message: "Another request is in progress", details: nil))
    }
    pendingSetHome = result
    pendingRadius = max(100, min(radius ?? GeofenceTrigger.defaultRadius, 1000))

    switch manager.authorizationStatus {
      case .notDetermined, .authorizedWhenInUse:
        // Wait for the authorization callback, then request a fix
        manager.requestAlwaysAuthorization()
      case .authorizedAlways:
        manager.requestLocation()
      default:
        finishSetHome(FlutterError(code: "denied", message: "Location permission denied", details: nil))
    }
  }

  private func disable() {
    for region in manager.monitoredRegions where region.identifier == GeofenceTrigger.regionIdentifier {
      manager.stopMonitoring(for: region)
    }
    UserDefaults.standard.removeObject(forKey: GeofenceTrigger.defaultsKey)
  }

  private func finishSetHome(_ value: Any) {
    guard let result = pendingSetHome else { return }
    pendingSetHome = nil
    result(value)
  }

  // MARK: - Storage

  private func storedRegion() -> CLCircularRegion? {
    guard let values = UserDefaults.standard.array(forKey: GeofenceTrigger.defaultsKey) as? [Double], values.count == 3 else {
      return nil
    }
    let region = CLCircularRegion(
      center: CLLocationCoordinate2D(latitude: values[0], longitude: values[1]),
      radius: values[2],
      identifier: GeofenceTrigger.regionIdentifier
    )
    region.notifyOnEntry = true
    region.notifyOnExit = false
    return region
  }

  private func store(center: CLLocationCoordinate2D, radius: CLLocationDistance) {
    UserDefaults.standard.set([center.latitude, center.longitude, radius], forKey: GeofenceTrigger.defaultsKey)
  }

  // MARK: - Worker

  private func runWorker(reason: String) {
    // Ask for a processing slot right away so that work not finished within our short window
    // can continue as soon as the system lets us.
    BackgroundWorkerApiImpl.scheduleProcessingWorker(delaySeconds: 0)

    // The foreground app already syncs and uploads on its own.
    if UIApplication.shared.applicationState == .active {
      print("GeofenceTrigger: app active, skipping worker (\(reason))")
      return
    }

    var bgTask: UIBackgroundTaskIdentifier = .invalid
    var worker: BackgroundWorker?
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "immich.geofence") {
      print("GeofenceTrigger: background time expired")
      worker?.close()
    }
    print("GeofenceTrigger: starting worker (\(reason))")
    worker = BackgroundWorkerApiImpl.runStandaloneWorker(maxSeconds: GeofenceTrigger.workerBudgetSeconds) { success in
      print("GeofenceTrigger: worker finished success=\(success)")
      if bgTask != .invalid {
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
      }
    }
    if worker == nil, bgTask != .invalid {
      UIApplication.shared.endBackgroundTask(bgTask)
    }
  }

  // MARK: - CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    print("GeofenceTrigger: authorization \(authorizationName(status))")
    if pendingSetHome != nil {
      switch status {
        case .authorizedAlways, .authorizedWhenInUse:
          // A one-off fix works with When-In-Use; monitoring itself needs Always, which iOS may
          // grant provisionally now and confirm with the user later.
          manager.requestLocation()
        case .notDetermined:
          break
        default:
          finishSetHome(FlutterError(code: "denied", message: "Location permission denied", details: nil))
      }
    } else if status == .authorizedAlways {
      start()
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard pendingSetHome != nil, let location = locations.last else { return }
    disable()
    store(center: location.coordinate, radius: pendingRadius)
    start()
    finishSetHome(status())
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    finishSetHome(FlutterError(code: "location", message: error.localizedDescription, details: nil))
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard region.identifier == GeofenceTrigger.regionIdentifier else { return }
    runWorker(reason: "didEnterRegion")
  }

  func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
    print("GeofenceTrigger: monitoring failed \(error.localizedDescription)")
  }

  private func authorizationName(_ status: CLAuthorizationStatus) -> String {
    switch status {
      case .notDetermined: return "notDetermined"
      case .restricted: return "restricted"
      case .denied: return "denied"
      case .authorizedAlways: return "always"
      case .authorizedWhenInUse: return "whenInUse"
      @unknown default: return "unknown"
    }
  }
}
