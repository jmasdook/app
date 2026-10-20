import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'core/env.dart';
import 'core/secure_storage.dart';
import 'core/theme.dart';
import 'features/auth/auth_screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Env.isConfigured) {
    // Never fall back to fake data: tell the developer exactly what to configure.
    runApp(MaterialApp(theme: buildTheme(), home: const ConfigMissingScreen()));
    return;
  }
  await Supabase.initialize(
    url: Env.supabaseUrl,
    // ignore: deprecated_member_use
    anonKey: Env.supabaseAnonKey,
    authOptions: FlutterAuthClientOptions(localStorage: SecureLocalStorage()),
  );
  runApp(const ProviderScope(child: SkillConnectApp()));
}
