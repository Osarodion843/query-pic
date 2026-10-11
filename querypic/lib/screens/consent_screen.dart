import 'package:flutter/material.dart';
import '../services/consent_store.dart';
import 'folder_picker_screen.dart';

/// Task 2: Privacy + telemetry consent. Opt-IN, default OFF (PRD §7).
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _optIn = false; // default off — never pre-ticked.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'All media processing is 100% local. '
              'Only anonymous crash diagnostics may leave the device — '
              'file paths, queries, folder names, locations and vectors '
              'are stripped on-device first. Only stack traces, OS version '
              'and device model are sent.',
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Anonymous crash reports'),
              subtitle: const Text('Off by default. You can change this later.'),
              value: _optIn,
              onChanged: (v) => setState(() => _optIn = v),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  await ConsentStore.setTelemetryOptIn(_optIn);
                  await ConsentStore.setCrashOptIn(_optIn);
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const FolderPickerScreen(
                            firstRun: true,),),
                  );
                },
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
