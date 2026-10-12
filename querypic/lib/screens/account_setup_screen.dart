import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/account_store.dart';
import '../services/app_index.dart';
import '../services/license_store.dart';
import '../services/pro_gate.dart';
import '../app_flavor.dart';
import 'welcome_screen.dart';

/// Account creation. First run: creates the device ADMIN (name + PIN —
/// the PIN guards every admin/debug area). Later additions (from
/// Settings, admin-only entry) create normal profiles; granting admin
/// requires confirming the existing PIN.
/// Migrates any pre-account global Pro/license onto the first profile so
/// existing installs keep their unlock.
class AccountSetupScreen extends StatefulWidget {
  final bool firstRun;
  final bool adminEntry;
  const AccountSetupScreen({
    super.key,
    this.firstRun = false,
    this.adminEntry = false,
  });

  @override
  State<AccountSetupScreen> createState() => _AccountSetupScreenState();
}

class _AccountSetupScreenState extends State<AccountSetupScreen> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final _pin2 = TextEditingController();
  bool _makeAdmin = false;
  bool _busy = false;
  String? _error;

  bool get _needsPin =>
      !kPublicBuild && (widget.firstRun || _makeAdmin);

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _pin2.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_needsPin) {
        if (_pin.text.length < 4) {
          setState(() {
            _error = 'PIN needs at least 4 digits.';
            _busy = false;
          });
          return;
        }
        if (_pin.text != _pin2.text) {
          setState(() {
            _error = 'PINs do not match.';
            _busy = false;
          });
          return;
        }
      }
      // Admin grants must prove the existing PIN (when one exists).
      if (_makeAdmin && !widget.firstRun && await AccountStore.hasPin) {
        if (!await AccountStore.verifyPin(_pin.text)) {
          if (!mounted) return;
          setState(() {
            _error = 'Wrong admin PIN — grant refused.';
            _busy = false;
          });
          return;
        }
      }
      final profile = await AccountStore.create(
        name: _name.text,
        // Public builds never create admins (no PIN step at all);
        // private builds make the first profile the administrator.
        isAdmin: !kPublicBuild && (widget.firstRun || _makeAdmin),
        pin: _needsPin ? _pin.text : null,
        allowFirstAdmin: !kPublicBuild,
      );
      // Migrate a pre-account global unlock onto the first profile.
      if (widget.firstRun) {
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool(ProTierStore.keyPro) ?? false) {
          await ProTierStore.setPro(true);
          final legacyKey = prefs.getString(LicenseStore.keyLicense);
          if (legacyKey != null && legacyKey.isNotEmpty) {
            await LicenseStore.save(legacyKey);
          }
        }
        // First profile becomes active automatically (store default).
        await prefs.setString(AccountStore.keyActive, profile.id);
      }
      await AppIndex.ensure().then((app) async {
        app.search.gate.isPro = await ProTierStore.isPro();
      }).catchError((_) {});
      if (!mounted) return;
      if (widget.firstRun) {
        // Continue onboarding (welcome -> consent -> folders).
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => const WelcomeScreen(),
          ),
          (_) => false,
        );
      } else {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.firstRun
              ? 'Create your account'
              : 'Add account',
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.firstRun
                    ? kPublicBuild
                        ? 'Create your personal profile. Accounts live '
                            'only on this device, and each one unlocks '
                            'Pro with its own license key.'
                        : 'The first account on this phone is the '
                            'administrator — it guards the developer '
                            'tools with a PIN. Accounts live only on '
                            'this device. Your existing library, '
                            'folders and Pro unlock carry over untouched.'
                    : widget.adminEntry
                        ? 'New profiles are normal users. Toggle below to '
                            'grant admin (requires the admin PIN).'
                        : 'New profiles are normal users.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  hintText: 'e.g. Osas',
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.adminEntry && !widget.firstRun && !kPublicBuild) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('Administrator'),
                  value: _makeAdmin,
                  onChanged: (v) => setState(() => _makeAdmin = v),
                ),
              ],
              if (_needsPin) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  decoration: InputDecoration(
                    labelText: widget.firstRun
                        ? 'Admin PIN (4+ digits)'
                        : 'Confirm admin PIN',
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin2,
                  decoration: const InputDecoration(
                    labelText: 'Repeat PIN',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _create,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
