import SwiftUI

/// The tile long-press menu's "Add a public list to Home". It reuses the
/// editor's own Trakt and MDBList pickers — the sheets Settings already
/// presents — and pins the result with `CollectionQuickAdd`, so both entry
/// points produce the same collection rather than two half-matching ones.
struct PublicListToHomeSheet: View {
    var onDismiss: () -> Void

    @State private var provider = Provider.trakt
    /// Remounts the picker when the provider changes, so the other sheet's
    /// half-typed fields never bleed into this one.
    @State private var pickerIdentity = 0

    private enum Provider: String, CaseIterable, Identifiable {
        case trakt = "Trakt"
        case mdblist = "MDBList"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(L10n.string(
                "quick_add_public_list_title",
                fallback: "Add a public list to Home"
            ))
            .font(.system(size: 30, weight: .semibold))
            .foregroundColor(.white)

            HStack(spacing: 12) {
                ForEach(Provider.allCases) { option in
                    CollectionChipButton(title: option.rawValue, isSelected: provider == option) {
                        guard provider != option else { return }
                        provider = option
                        pickerIdentity &+= 1
                    }
                }
            }

            Group {
                switch provider {
                case .trakt:
                    CollectionTraktSourceSheet(accentColor: .white) { source in
                        save(source, fallbackTitle: "Trakt List")
                    }
                case .mdblist:
                    CollectionMdbListSourceSheet(accentColor: .white) { source in
                        save(source, fallbackTitle: "MDBList List")
                    }
                }
            }
            .id(pickerIdentity)
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save(_ source: [String: Any], fallbackTitle: String) {
        CollectionQuickAdd.addList(source: source, fallbackTitle: fallbackTitle)
        onDismiss()
    }
}
