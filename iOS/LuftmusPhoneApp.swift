import SwiftUI

// iPhone-delen är bara ett skal: den bär med sig klockappen.
@main
struct LuftmusPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 16) {
                Text("😎").font(.system(size: 64))
                Text("Luftmus").font(.largeTitle).bold()
                Text("Öppna Luftmus på klockan.\n\nSyns den inte där? Öppna appen Watch på iPhonen, scrolla ner till \"Tillgängliga appar\" och tryck Installera vid Luftmus.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }
}
