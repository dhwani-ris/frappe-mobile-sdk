/// System-defined OAuth redirect URI for Frappe Mobile SDK.
///
/// Use this exact value when creating an OAuth Client in Frappe:
/// 1. Go to Frappe: Setup → Integrations → OAuth Provider
/// 2. Create OAuth Client
/// 3. Set Redirect URI to: [oauthRedirectUri]
const String oauthRedirectUri = 'frappemobilesdk://oauth/callback';
