import SwiftUI

/// The app is account-scoped. No local console is mounted until a valid
/// Supabase session exists, which prevents a second user's local catalog from
/// being shown before the cloud gallery boundary has been established.
struct RealPetRootView: View {
    @EnvironmentObject private var vm: PetListViewModel
    @ObservedObject private var googleLogin = SupabaseGoogleLoginCoordinator.shared

    let bridge: PythonBridge

    var body: some View {
        Group {
            switch googleLogin.state {
            case .signedIn:
                if vm.cloudAccountIsReady {
                    MainPanelView(bridge: bridge)
                } else if let error = vm.cloudGalleryError {
                    GoogleLoginGateView(
                        title: "无法打开云端图库",
                        detail: error,
                        isLoading: false,
                        actionTitle: "重试",
                        action: vm.activateCloudGallery)
                } else {
                    GoogleLoginGateView(
                        title: "正在打开云端图库…",
                        detail: nil,
                        isLoading: true,
                        actionTitle: nil,
                        action: {})
                }
            case .checking:
                GoogleLoginGateView(
                    title: "正在检查登录状态…",
                    detail: nil,
                    isLoading: true,
                    actionTitle: nil,
                    action: {})
            case .signedOut:
                GoogleLoginGateView(
                    title: "使用 Google 登录",
                    detail: "登录后管理你的云端宠物图库",
                    isLoading: false,
                    actionTitle: "使用 Google 登录",
                    action: googleLogin.signIn)
            case .signingIn:
                GoogleLoginGateView(
                    title: "正在等待 Google 授权…",
                    detail: nil,
                    isLoading: true,
                    actionTitle: nil,
                    action: {})
            case .failed(let message):
                GoogleLoginGateView(
                    title: "Google 登录未完成",
                    detail: message,
                    isLoading: false,
                    actionTitle: "重新使用 Google 登录",
                    action: googleLogin.signIn)
            }
        }
        .frame(width: 540)
        .task(id: googleLogin.state.isSignedIn) {
            if googleLogin.state.isSignedIn {
                vm.activateCloudGallery()
            }
        }
        .onChange(of: googleLogin.state) { _, state in
            guard !state.isSignedIn else { return }
            if let pet = vm.pet, pet.status == .showing {
                vm.hidePet(pet)
            }
            vm.clearCloudAccountSession()
        }
    }
}

private struct GoogleLoginGateView: View {
    let title: String
    let detail: String?
    let isLoading: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.blue)
            Text("RealPet")
                .font(.title2.weight(.semibold))
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
            }
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 330)
        .padding(24)
    }
}
