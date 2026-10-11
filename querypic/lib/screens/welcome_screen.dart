import 'package:flutter/material.dart';
import '../widgets/privacy_badge.dart';
import 'consent_screen.dart';

/// Task 1: Welcome — "100% On-Device & Private" + what gets indexed.
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PrivacyBadge(),
              const SizedBox(height: 16),
              Text('Your photos,\nfindable by words.',
                  style: Theme.of(context).textTheme.headlineMedium,),
              const SizedBox(height: 12),
              const Text(
                'QueryPic searches your photos and videos entirely on this '
                'device — objects, scenes, text in images, and spoken words. '
                'Nothing is uploaded. You choose exactly which folders it '
                'may look at.',
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ConsentScreen(),),
                  ),
                  child: const Text('Get Started'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
