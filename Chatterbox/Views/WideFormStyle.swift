import SwiftUI

/// Settings' grouped form, using the page's whole width (macOS's grouped Form stops at about
/// 680 points). Sections keep their header, rounded box, dividers and footer; switches and
/// labeled values sit at the right edge as in a grouped form. Before macOS 15, the system style.
struct WideFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 15.0, *) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(sections: configuration.content) { section in
                        WideFormSection(section: section)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(SpreadSwitchStyle())
            .labeledContentStyle(SpreadLabeledContentStyle())
        } else {
            Form { configuration.content }.formStyle(.grouped)
        }
    }
}

@available(macOS 15.0, *)
private struct WideFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !section.header.isEmpty {
                section.header
                    .font(.headline)
                    .padding(.leading, 2)
            }
            if !section.content.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.content.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        row
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
            if !section.footer.isEmpty {
                section.footer
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A label on the left and a switch at the right edge, as in a grouped form.
private struct SpreadSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A label on the left and its value or control at the right edge.
private struct SpreadLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content.foregroundStyle(.secondary)
        }
    }
}
