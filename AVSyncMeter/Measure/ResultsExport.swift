import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// CSV of every flash/beep pair, shareable through ShareLink.
struct ResultsExport: Transferable {
    let csv: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { export in
            Data(export.csv.utf8)
        }
        .suggestedFileName("avsync_results.csv")
    }
}
