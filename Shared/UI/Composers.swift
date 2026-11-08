import CoreLocation
import MapKit
import SwiftUI

/// Abstimmung anlegen: Frage, Antworten (leeres Feld erscheint automatisch), Mehrfachauswahl, Zwischenstand.
struct PollComposer: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String, [String], Bool, Bool) -> Void
    @State private var question = ""
    @State private var options: [String] = ["", ""]
    @State private var multi = false
    @State private var interim = true

    var clean: [String] { options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Frage, z. B. Was kochen wir am Sonntag?", text: $question, axis: .vertical)
                        .accessibilityIdentifier("poll.question")
                }
                Section("Antworten") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            TextField("Antwort hinzufügen", text: Binding(get: { options[i] }, set: { v in
                                options[i] = v
                                if i == options.count - 1 && !v.isEmpty && options.count < 50 { options.append("") }
                            }))
                            .accessibilityIdentifier("poll.option.\(i)")
                            #if os(iOS)
                            Button {
                                options[i] = Date().addingTimeInterval(86400).formatted(.dateTime.weekday(.abbreviated).day().month())
                                if i == options.count - 1 { options.append("") }
                            } label: { Image(systemName: "calendar") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Datum eintragen"))
                            #endif
                        }
                    }
                    .onDelete { options.remove(atOffsets: $0); if options.isEmpty { options = [""] } }
                }
                Section {
                    Toggle("Mehrere Antworten erlauben", isOn: $multi)
                    Toggle("Zwischenstand zeigen", isOn: $interim)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Abstimmung anlegen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ablegen") {
                        onCreate(question.trimmingCharacters(in: .whitespacesAndNewlines), clean, multi, interim)
                        dismiss()
                    }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || clean.count < 2)
                    .accessibilityIdentifier("poll.create")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }
}

/// Checkliste anlegen: Titel + Punkte.
struct ChecklistComposer: View {
    @Environment(\.dismiss) private var dismiss
    var onCreate: (String, [String]) -> Void
    @State private var title = ""
    @State private var items: [String] = [""]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel, z. B. Einkauf", text: $title).accessibilityIdentifier("checklist.title")
                }
                Section("Punkte") {
                    ForEach(items.indices, id: \.self) { i in
                        HStack {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            TextField("Punkt hinzufügen", text: Binding(get: { items[i] }, set: { v in
                                items[i] = v
                                if i == items.count - 1 && !v.isEmpty && items.count < 200 { items.append("") }
                            }))
                            .accessibilityIdentifier("checklist.item.\(i)")
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0); if items.isEmpty { items = [""] } }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Checkliste anlegen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ablegen") {
                        onCreate(title.trimmingCharacters(in: .whitespacesAndNewlines),
                                 items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && items.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                    .accessibilityIdentifier("checklist.create")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }
}

/// Einmal den aktuellen Ort holen.
@Observable
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    var location: CLLocation?
    var denied = false
    private let manager = CLLocationManager()

    func request() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        switch manager.authorizationStatus {
        case .notDetermined:
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #else
            manager.requestAlwaysAuthorization()
            #endif
        case .denied, .restricted: denied = true
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let st = m.authorizationStatus
        Task { @MainActor in
            if st == .denied || st == .restricted { self.denied = true } else if st != .notDetermined { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        let l = locs.last
        Task { @MainActor in self.location = l }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

/// Ort festhalten: aktueller Standort oder Punkt auf der Karte, mit eigenem Namen.
struct LocationPicker: View {
    @Environment(\.dismiss) private var dismiss
    var onPick: (Double, Double, String) -> Void
    @State private var fetcher = LocationFetcher()
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Map(position: $position) { UserAnnotation() }
                        .onMapCameraChange(frequency: .onEnd) { ctx in center = ctx.region.center }
                    Image(systemName: "mappin").font(.system(size: 34)).foregroundStyle(Theme.accent).offset(y: -17)
                        .allowsHitTesting(false)
                }
                .frame(minHeight: 260)
                Form {
                    Section {
                        TextField("Name des Orts (optional)", text: $name).accessibilityIdentifier("location.name")
                        TextField("Adresse oder Ort suchen", text: $query).onSubmit(search)
                        ForEach(results, id: \.self) { item in
                            Button {
                                let c = item.placemark.coordinate
                                position = .region(MKCoordinateRegion(center: c, latitudinalMeters: 500, longitudinalMeters: 500))
                                center = c
                                if name.isEmpty { name = item.name ?? "" }
                                results = []
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "")
                                    if let a = item.placemark.title { Text(a).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    } footer: {
                        if fetcher.denied {
                            Text("Kein Zugriff auf den Standort – verschiebe die Karte oder suche einen Ort.")
                        } else {
                            Text("Die Nadel in der Mitte wird festgehalten.")
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle("Ort festhalten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ablegen") {
                        let c = center ?? fetcher.location?.coordinate
                        if let c { onPick(c.latitude, c.longitude, name.trimmingCharacters(in: .whitespaces)) }
                        dismiss()
                    }
                    .disabled(center == nil && fetcher.location == nil)
                    .accessibilityIdentifier("location.add")
                }
            }
            .onAppear { fetcher.request() }
            .onChange(of: fetcher.location) { _, l in
                if let l, center == nil {
                    center = l.coordinate
                    position = .region(MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 500, longitudinalMeters: 500))
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func search() {
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = query
        Task {
            results = (try? await MKLocalSearch(request: r).start().mapItems.prefix(6)).map(Array.init) ?? []
        }
    }
}
