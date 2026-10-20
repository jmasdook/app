import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/env.dart';
import '../../data/providers.dart';
import '../common/widgets.dart';

String? validateEmail(String? v) => (v == null || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())) ? 'Enter a valid email address' : null;
String? validatePassword(String? v) => (v == null || v.length < 8) ? 'Use at least 8 characters' : null;

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with BusyMixin {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await run(() => ref.read(authRepoProvider).signIn(_email.text, _password.text));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Form(
                  key: _form,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(Env.brandName, style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    const Text('Trusted professionals, booked in minutes.'),
                    const SizedBox(height: 32),
                    TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], validator: validateEmail),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(labelText: 'Password', suffixIcon: IconButton(tooltip: 'Show password', icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _obscure = !_obscure))),
                      validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
                      onFieldSubmitted: (_) => _submit(),
                    ),
                    Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => context.push('/forgot'), child: const Text('Forgot password?'))),
                    const SizedBox(height: 8),
                    FilledButton(onPressed: busy ? null : _submit, child: busy ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5)) : const Text('Sign in')),
                    const SizedBox(height: 12),
                    OutlinedButton(onPressed: () => context.push('/register'), child: const Text('Create an account')),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> with BusyMixin {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _email = TextEditingController(), _password = TextEditingController();
  bool _asWorker = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    await run(() async {
      await ref.read(authRepoProvider).signUp(_email.text, _password.text, _name.text, asWorker: _asWorker);
      if (mounted && ref.read(authRepoProvider).userId == null) {
        showSnack(context, 'Check your email to confirm your account, then sign in.');
        context.pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Create account')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _form,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: false, label: Text('I need a service'), icon: Icon(Icons.home_repair_service)), ButtonSegment(value: true, label: Text("I'm a professional"), icon: Icon(Icons.engineering))],
                  selected: {_asWorker},
                  onSelectionChanged: (s) => setState(() => _asWorker = s.first),
                ),
                if (_asWorker) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Professionals are verified by our team before they can receive bookings.')),
                const SizedBox(height: 20),
                TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Full name'), validator: (v) => (v == null || v.trim().length < 2) ? 'Enter your name' : null),
                const SizedBox(height: 14),
                TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress, validator: validateEmail),
                const SizedBox(height: 14),
                TextFormField(controller: _password, decoration: const InputDecoration(labelText: 'Password', helperText: 'At least 8 characters'), obscureText: true, validator: validatePassword),
                const SizedBox(height: 24),
                FilledButton(onPressed: busy ? null : _submit, child: const Text('Create account')),
              ]),
            ),
          ),
        ),
      );
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotState();
}

class _ForgotState extends ConsumerState<ForgotPasswordScreen> with BusyMixin {
  final _email = TextEditingController();
  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Reset password')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text("Enter your email and we'll send a reset link."),
            const SizedBox(height: 16),
            TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: busy ? null : () => run(() async {
                    if (validateEmail(_email.text) != null) throw Exception('invalid email');
                    await ref.read(authRepoProvider).resetPassword(_email.text);
                    // Same message whether or not the account exists (no account enumeration).
                    if (!context.mounted) return;
                    showSnack(context, 'If that email has an account, a reset link is on its way.');
                    context.pop();
                  }),
              child: const Text('Send reset link'),
            ),
          ]),
        ),
      );
}

class ConfigMissingScreen extends StatelessWidget {
  const ConfigMissingScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Backend not configured', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              const Text('Build the app with your Supabase project values:'),
              const SizedBox(height: 8),
              const SelectableText('flutter run \\\n  --dart-define=SUPABASE_URL=https://xyz.supabase.co \\\n  --dart-define=SUPABASE_ANON_KEY=<anon key>'),
            ]),
          ),
        ),
      );
}
