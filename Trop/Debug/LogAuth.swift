//
//  LogAuth.swift
//  Trop
//
//  Created by 686udjie on 26/11/2026.
//

extension Log {
    static var login: AppLogger { make("Login", file: "auth") }
    static var loginViewModel: AppLogger { make("LoginViewModel", file: "auth") }
}
