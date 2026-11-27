import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LibreGlanceBundle: WidgetBundle {
  var body: some Widget {
    LibreGlanceLiveActivity()
  }
}

// The `live_activities` plugin requires this exact name and shape. App updates pass
// their data through the App Group UserDefaults (keys prefixed by the id) and leave
// ContentState empty; the server's APNs pushes fill ContentState instead (keys must
// match `content_state` in server/libreglance/poll.py).
struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState
  public struct ContentState: Codable, Hashable {
    var glucose: Int?
    var trend: Int?
    var timestampMs: Double?
    var minTarget: Int?
    var maxTarget: Int?
    var patient: String?
  }
  var id = UUID()
}

extension LiveActivitiesAppAttributes {
  func prefixedKey(_ key: String) -> String { "\(id)_\(key)" }
}

private let sharedDefault = UserDefaults(suiteName: "group.com.datally.libreglance")!

/// Typed view of the values written by LiveActivityManager (Dart side).
struct Reading {
  let value: Int
  let trend: Int  // 1...5
  let date: Date
  let minTarget: Int
  let maxTarget: Int
  let patientName: String
  let stale: Bool

  init(_ a: LiveActivitiesAppAttributes, state: LiveActivitiesAppAttributes.ContentState, stale: Bool) {
    self.stale = stale
    func int(_ k: String) -> Int { sharedDefault.integer(forKey: a.prefixedKey(k)) }
    let localMs = sharedDefault.double(forKey: a.prefixedKey("timestamp"))
    // Whichever source holds the newest reading wins (a push or the app's own update).
    let usePush = state.glucose != nil && (state.timestampMs ?? 0) >= localMs
    value = usePush ? state.glucose! : int("glucose")
    trend = usePush ? (state.trend ?? 3) : int("trend")
    // Never in the future: a clock skew would make the relative age count down.
    date = min(Date(timeIntervalSince1970: (usePush ? state.timestampMs ?? 0 : localMs) / 1000), Date())
    minTarget = usePush ? (state.minTarget ?? 70) : int("min")
    maxTarget = usePush ? (state.maxTarget ?? 180) : int("max")
    patientName = (usePush ? state.patient : sharedDefault.string(forKey: a.prefixedKey("patient"))) ?? ""
  }

  var color: Color {
    if stale { return .gray }
    return value < minTarget ? .red : (value > maxTarget ? .orange : .green)
  }
  var label: String {
    if stale { return "Données anciennes" }
    return value < minTarget ? "Bas" : (value > maxTarget ? "Élevé" : "Dans la cible")
  }
  var arrow: String {
    switch trend {
    case 1: return "↓"
    case 2: return "↘"
    case 4: return "↗"
    case 5: return "↑"
    default: return "→"
    }
  }
}

/// Position of the value relative to the target band (40 mg/dL margin each side).
struct TargetGauge: View {
  let r: Reading

  var body: some View {
    GeometryReader { geo in
      let lo = Double(r.minTarget - 40)
      let hi = Double(r.maxTarget + 40)
      let x: (Int) -> CGFloat = { v in
        CGFloat(min(max((Double(v) - lo) / (hi - lo), 0), 1)) * geo.size.width
      }
      ZStack(alignment: .leading) {
        Capsule().fill(.gray.opacity(0.3))
        Capsule().fill(.green.opacity(0.5))
          .frame(width: x(r.maxTarget) - x(r.minTarget))
          .offset(x: x(r.minTarget))
        Circle().fill(r.color).frame(width: 12, height: 12)
          .offset(x: x(r.value) - 6)
      }
    }
    .frame(height: 12)
  }
}

struct LockScreenView: View {
  let r: Reading

  var body: some View {
    VStack(spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text("\(r.value)").font(.system(size: 44, weight: .bold)).foregroundStyle(r.color)
        Text("mg/dL").font(.caption)
        Text(r.arrow).font(.title).foregroundStyle(r.color)
        Spacer()
        VStack(alignment: .trailing) {
          Text(r.label).font(.headline).foregroundStyle(r.color)
          Text(r.date, style: .time).font(.caption)
        }
      }
      TargetGauge(r: r)
    }
    .padding()
  }
}

struct LibreGlanceLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      LockScreenView(r: Reading(context.attributes, state: context.state, stale: context.isStale))
    } dynamicIsland: { context in
      let r = Reading(context.attributes, state: context.state, stale: context.isStale)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text("\(r.value)").font(.system(size: 36, weight: .bold)).foregroundStyle(r.color)
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing) {
            Text(r.arrow).font(.title2).foregroundStyle(r.color)
            Text(r.label).font(.caption).foregroundStyle(r.color)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(spacing: 6) {
            TargetGauge(r: r)
            Text("mg/dL · \(r.date, style: .time)").font(.caption2)
          }
        }
      } compactLeading: {
        HStack(spacing: 4) {
          Circle().fill(r.color).frame(width: 8, height: 8)
          Text("\(r.value)").bold()
        }
      } compactTrailing: {
        HStack(spacing: 2) {
          Text(r.arrow)
          Text(r.date, style: .relative)
            .monospacedDigit()
            .frame(maxWidth: 40)
        }
      } minimal: {
        Text("\(r.value)\(r.arrow)").font(.caption2).foregroundStyle(r.color)
      }
    }
  }
}
