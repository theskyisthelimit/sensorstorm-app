import SensorstormCore
import SwiftUI

/// The scans kept from earlier visits, newest first. Opening one shows what changed since the
/// scan before it.
struct NetworkInventoryView: View {
    @Environment(NetworkHub.self) private var network

    var body: some View {
        List {
            if network.inventory.snapshots.isEmpty {
                Section {
                    Text("Noch kein Scan gespeichert. Jede abgeschlossene Suche im Netz landet hier.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(network.inventory.snapshots) { snapshot in
                NavigationLink {
                    SnapshotDetailView(snapshot: snapshot)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: snapshot.networkName)
                        HStack(spacing: 6) {
                            Text(snapshot.date, format: .dateTime.day().month().year().hour().minute())
                            Text(verbatim: "·")
                            Text("\(snapshot.hosts.count) Geräte")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let snapshots = network.inventory.snapshots
                for index in offsets { network.inventory.delete(snapshots[index]) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Gespeicherte Scans")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SnapshotDetailView: View {
    @Environment(NetworkHub.self) private var network
    let snapshot: NetworkSnapshot

    var body: some View {
        List {
            Section {
                LabeledContent("Netz") { Text(verbatim: snapshot.subnet).monospaced() }
                if let gateway = snapshot.gateway {
                    LabeledContent("Router") { Text(verbatim: gateway).monospaced() }
                }
            }
            if let previous = network.inventory.previous(to: snapshot) {
                let diff = InventoryDiff.between(previous, snapshot)
                Section {
                    if diff.isEmpty {
                        Text("Nichts hat sich verändert.").foregroundStyle(.secondary)
                    }
                    ForEach(diff.added) { host in
                        Label { Text(verbatim: "\(host.displayName) · \(host.address)") } icon: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                        }
                    }
                    ForEach(diff.removed) { host in
                        Label { Text(verbatim: "\(host.displayName) · \(host.address)") } icon: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(Theme.recording)
                        }
                    }
                    ForEach(diff.changed, id: \.address) { change in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(change.name) · \(change.address)")
                            if !change.openedPorts.isEmpty {
                                Label("Neu offen: \(NetFormat.ports(change.openedPorts))", systemImage: "lock.open")
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            if !change.closedPorts.isEmpty {
                                Label("Jetzt zu: \(NetFormat.ports(change.closedPorts))", systemImage: "lock")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Seit \(previous.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            Section {
                ForEach(snapshot.hosts) { host in
                    NavigationLink {
                        HostDetailView(host: host, subnet: snapshot.subnet, gateway: snapshot.gateway)
                    } label: {
                        HostRow(host: host,
                                annotation: network.inventory.annotation(address: host.address, subnet: snapshot.subnet),
                                isSelf: false, isGateway: host.address == snapshot.gateway)
                    }
                }
            } header: {
                Text("\(snapshot.hosts.count) Geräte")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(Text(snapshot.date, format: .dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: snapshot.csv()) {
                    Label("Als Tabelle teilen", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}
