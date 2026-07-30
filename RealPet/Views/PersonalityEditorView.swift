import SwiftUI

struct PersonalityEditorView: View {
    let pet: Pet
    let onCancel: () -> Void
    let onSave: (PetPersonality) -> Void

    @State private var energy: Double
    @State private var curiosity: Double
    @State private var affection: Double
    @State private var boldness: Double
    @State private var playfulness: Double
    @State private var independence: Double

    init(
        pet: Pet,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PetPersonality) -> Void
    ) {
        self.pet = pet
        self.onCancel = onCancel
        self.onSave = onSave
        let personality = pet.personality ?? .balanced
        _energy = State(initialValue: personality.energy)
        _curiosity = State(initialValue: personality.curiosity)
        _affection = State(initialValue: personality.affection)
        _boldness = State(initialValue: personality.boldness)
        _playfulness = State(initialValue: personality.playfulness)
        _independence = State(initialValue: personality.independence)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text("自定义性格")
                    .font(.headline)
                Spacer()
            }

            Text(pet.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Divider()

            traitRow("能量", symbol: "bolt", value: $energy)
            traitRow("好奇", symbol: "eye", value: $curiosity)
            traitRow("亲近", symbol: "heart", value: $affection)
            traitRow("胆量", symbol: "shield", value: $boldness)
            traitRow("爱玩", symbol: "sparkles", value: $playfulness)
            traitRow("独立", symbol: "moon", value: $independence)

            Divider()

            HStack {
                Button {
                    apply(.balanced)
                } label: {
                    Label("恢复均衡", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(PetPersonality.customized(
                        energy: energy,
                        curiosity: curiosity,
                        affection: affection,
                        boldness: boldness,
                        playfulness: playfulness,
                        independence: independence))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 430)
    }

    private func traitRow(
        _ title: String,
        symbol: String,
        value: Binding<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .frame(width: 72, alignment: .leading)
            Slider(value: value, in: 0...1, step: 0.05)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func apply(_ personality: PetPersonality) {
        energy = personality.energy
        curiosity = personality.curiosity
        affection = personality.affection
        boldness = personality.boldness
        playfulness = personality.playfulness
        independence = personality.independence
    }
}
