// SignInView.swift
// WhiteBoARd - Spatial AR Notetaking
//
// Email/password sign-in. The account chosen here decides which user's notes
// sync to the web companion.

import SwiftUI

struct SignInView: View {
    @Environment(AuthService.self) private var auth

    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @State private var creatingAccount = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                VStack(spacing: 8) {
                    Text("SpatialBoard")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(creatingAccount ? "Create your account" : "Sign in so your notes sync to the web.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(creatingAccount ? .newPassword : .password)
                }
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if busy { ProgressView().tint(.black) }
                        else { Text(creatingAccount ? "Create account" : "Sign in").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: 320)
                    .padding(.vertical, 14)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.black)
                }
                .disabled(busy || email.isEmpty || password.isEmpty)

                Button(creatingAccount ? "Have an account? Sign in" : "New here? Create an account") {
                    creatingAccount.toggle()
                    error = nil
                }
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding()
        }
    }

    private func submit() async {
        busy = true
        error = nil
        let result = creatingAccount
            ? await auth.signUp(email: email, password: password)
            : await auth.login(email: email, password: password)
        busy = false
        if let result { error = result }
    }
}
