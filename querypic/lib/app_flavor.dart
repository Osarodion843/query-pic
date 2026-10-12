/// Build flavor: private admin APK vs public user APK.
///
/// Two artifacts, one codebase, same applicationId (interchangeable
/// installs, data preserved):
///   Admin (private, yours):  flutter build apk --release
///     First account is the administrator (PIN); developer tools visible
///     to admins; full account management. NEVER on the public site.
///   Public (Render site):    flutter build apk --release
///                              --dart-define=PUBLIC_BUILD=true
///     First account is a plain user (no PIN step); developer tools and
///     admin grants are compiled OUT of reach — no admin can ever exist,
///     so normal profiles are all there is. Users unlock Pro per account
///     through Paystack license keys and manage (switch/delete) their own
///     profiles freely.
const bool kPublicBuild =
    bool.fromEnvironment('PUBLIC_BUILD', defaultValue: false);
