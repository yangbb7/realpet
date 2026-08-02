import AppKit
import AuthenticationServices
import Combine

enum SupabaseGoogleLoginState: Equatable {
    case checking
    case signedOut
    case signingIn
    case signedIn(SupabaseGoogleAccount)
    case failed(String)

    var isSignedIn: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

/// Presents the system-authenticated browser session. The browser receives
/// Google credentials directly; RealPet only receives the resulting Supabase
/// session from its registered deep-link callback.
@MainActor
final class SupabaseGoogleLoginCoordinator: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {
    static let shared = SupabaseGoogleLoginCoordinator()

    @Published private(set) var state: SupabaseGoogleLoginState = .checking

    private var authenticationSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        refreshStatus()
    }

    func refreshStatus() {
        if case .signingIn = state { return }
        state = .checking
        Task { [weak self] in
            do {
                let configuration = try BundledSupabaseReferenceStorage.configuration()
                _ = try await SupabaseGoogleSessionStore.shared.credentials(
                    configuration: configuration,
                    publishableKey: try BundledSupabaseReferenceStorage.publishableKey())
                let account = await SupabaseGoogleSessionStore.shared.account()
                self?.state = account.map(SupabaseGoogleLoginState.signedIn) ?? .signedOut
            } catch let error as SupabaseGoogleSessionError {
                if error == .signInRequired {
                    self?.state = .signedOut
                } else {
                    self?.state = .failed(error.localizedDescription)
                }
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func signIn() {
        if case .signingIn = state { return }
        do {
            let configuration = try BundledSupabaseReferenceStorage.configuration()
            let url = try SupabaseGoogleSessionStore.authorizationURL(
                configuration: configuration)
            state = .signingIn
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: SupabaseGoogleSessionStore.callbackURL.scheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    self?.finishSignIn(callbackURL: callbackURL, error: error)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                state = .failed("无法打开 Google 登录窗口")
                return
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func signOut() {
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            let configuration = try? BundledSupabaseReferenceStorage.configuration()
            let publishableKey = try? BundledSupabaseReferenceStorage.publishableKey()
            if let configuration, let publishableKey {
                await SupabaseGoogleSessionStore.shared.signOut(
                    configuration: configuration, publishableKey: publishableKey)
            }
            self.state = .signedOut
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
    }

    private func finishSignIn(callbackURL: URL?, error: Error?) {
        authenticationSession = nil
        if let error {
            if let authError = error as? ASWebAuthenticationSessionError,
               authError.code == .canceledLogin {
                state = .signedOut
            } else {
                state = .failed(error.localizedDescription)
            }
            return
        }
        guard let callbackURL else {
            state = .failed("Google 登录没有返回回调地址")
            return
        }
        Task { [weak self] in
            do {
                let configuration = try BundledSupabaseReferenceStorage.configuration()
                let publishableKey = try BundledSupabaseReferenceStorage.publishableKey()
                let account = try await SupabaseGoogleSessionStore.shared.completeAuthorization(
                    callbackURL: callbackURL,
                    configuration: configuration,
                    publishableKey: publishableKey)
                self?.state = .signedIn(account)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }
}
