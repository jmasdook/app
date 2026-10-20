/// Build-time configuration, supplied with --dart-define. Only PUBLIC values belong here
/// (Supabase URL + anon key). Service-role keys and payment secrets must never be put in the app.
class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const brandName = String.fromEnvironment('BRAND_NAME', defaultValue: 'SkillConnect');
  static const defaultCurrency = String.fromEnvironment('DEFAULT_CURRENCY', defaultValue: 'AED');

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
