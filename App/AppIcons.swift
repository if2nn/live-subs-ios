import SwiftUI
import UIKit

/// App 图标 (plan §12.5, §12.6). The system is the source of truth for the
/// current icon; nothing is stored in the app.
enum AppIconChoice: String, CaseIterable, Identifiable {
 case orange = "Orange", blue = "Blue", green = "Green", pink = "Pink", yellow = "Yellow", purple = "Purple", teal = "Teal"
 var id: String { rawValue }
 /// nil = primary icon (AppIcon, orange).
 var iconName: String? { self == .orange ? nil : "AppIcon-" + rawValue }
 var preview: String { "IconPreview-" + rawValue }
 var label: String {
  switch self {
  case .orange: return S.iconOrange
  case .blue: return S.iconBlue
  case .green: return S.iconGreen
  case .pink: return S.iconPink
  case .yellow: return S.iconYellow
  case .purple: return S.iconPurple
  case .teal: return S.iconTeal
  }
 }
 var spoken: String { S.iconSpoken + label.replacingOccurrences(of: S.iconDefaultSuffix, with: "") + S.iconColorSuffix }
 static func from(_ name: String?) -> AppIconChoice { allCases.first { $0.iconName == name } ?? .orange }
}

struct AppIconSection: View {
 @State private var current = AppIconChoice.from(UIApplication.shared.alternateIconName)
 @State private var error = ""
 private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

 var body: some View {
  if UIApplication.shared.supportsAlternateIcons {
   Section {
    LazyVGrid(columns: columns, spacing: 14) {
     ForEach(AppIconChoice.allCases) { choice in
      Button { select(choice) } label: {
       VStack(spacing: 6) {
        Image(choice.preview).resizable().scaledToFit()
         .frame(width: 58, height: 58)
         .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
         .overlay {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
           .strokeBorder(choice == current ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: choice == current ? 3 : 1)
         }
         .overlay(alignment: .bottomTrailing) {
          if choice == current {
           Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).offset(x: 4, y: 4)
          }
         }
        Text(choice.label).font(.caption2).foregroundStyle(.primary).lineLimit(1)
       }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(choice.spoken)
      .accessibilityAddTraits(choice == current ? .isSelected : [])
      .accessibilityIdentifier("settings.icon." + choice.rawValue)
     }
    }.padding(.vertical, 6)
    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("settings.icon.error") }
   } header: { Text(S.sectionAppIcon) }
   .onAppear { current = AppIconChoice.from(UIApplication.shared.alternateIconName) }
  }
 }

 private func select(_ choice: AppIconChoice) {
  guard choice != current else { return }
  Task { @MainActor in
   do {
    try await UIApplication.shared.setAlternateIconName(choice.iconName)
    error = ""
    Diagnostics.record("icon.changed")
   } catch {
    self.error = S.iconFailed
    Diagnostics.record("icon.change.failed")
   }
   current = AppIconChoice.from(UIApplication.shared.alternateIconName)
  }
 }
}
