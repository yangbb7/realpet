import SwiftUI

struct CustomActionNameView: View {
    @Binding var name: String

    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var canConfirm: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("命名自定义动作")
                .font(.title3.weight(.semibold))
            TextField("动作名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if canConfirm { onConfirm() }
                }
            HStack {
                Button("取消", role: .cancel, action: onCancel)
                Spacer()
                Button("导入并转换", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
