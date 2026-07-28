import SwiftUI
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// `URL` isn't `Identifiable`, and `.sheet(item:)` needs it to be.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
