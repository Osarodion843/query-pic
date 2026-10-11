import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../services/app_index.dart';
import '../services/media_source.dart';
import '../services/query_engine.dart';
import '../theme.dart';
import 'result_opener.dart';

/// Phase 5, task 5: results of a "Find similar" query (Pro).
class SimilarScreen extends StatelessWidget {
  final String queryLabel;
  final List<RankedResult> results;
  const SimilarScreen({
    super.key,
    required this.queryLabel,
    required this.results,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(queryLabel)),
      body: results.isEmpty
          ? const Center(child: Text('No similar items found.'))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: results.length,
              itemBuilder: (context, i) => _ResultCard(
                result: results[i],
                onTap: () => _preview(context, results[i]),
              ),
            ),
    );
  }

  void _preview(BuildContext context, RankedResult result) {
    final date = DateTime.fromMillisecondsSinceEpoch(result.mtime);
    final isPro = AppIndex.current?.search.gate.isPro ?? false;
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.uri.split('/').last,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '${result.isVideo ? 'Video' : 'Photo'} · '
              '${date.year}-${date.month.toString().padLeft(2, '0')}-'
              '${date.day.toString().padLeft(2, '0')} · '
              '${result.score}% match',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => openRankedResult(
                  context,
                  result,
                  isPro: isPro,
                ),
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  result.isVideo
                      ? 'Open in native player'
                      : 'Open in gallery app',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final RankedResult result;
  final VoidCallback onTap;
  const _ResultCard({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final band = result.band;
    final pill = band == ScoreBand.high
        ? const Color(0xFF16A34A)
        : band == ScoreBand.mid
            ? const Color(0xFFD97706)
            : const Color(0xFF6B7280);
    final assetId = photoAssetIdFromUri(result.uri);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: QueryPicColors.borderLight),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (assetId != null)
              FutureBuilder<AssetEntity?>(
                future: AssetEntity.fromId(assetId),
                builder: (context, snap) {
                  final asset = snap.data;
                  if (asset == null) return const _ThumbFallback();
                  return FutureBuilder<Uint8List?>(
                    future: asset.thumbnailDataWithSize(
                      const ThumbnailSize.square(300),
                    ),
                    builder: (context, thumb) {
                      final bytes = thumb.data;
                      if (bytes == null) return const _ThumbFallback();
                      return Image.memory(bytes, fit: BoxFit.cover);
                    },
                  );
                },
              )
            else
              const _ThumbFallback(),
            if (result.isVideo)
              const Positioned(
                left: 6,
                bottom: 6,
                child: Icon(Icons.videocam, size: 16, color: Colors.white),
              ),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: pill,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${result.score}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while a thumbnail loads or when the asset is gone.
class _ThumbFallback extends StatelessWidget {
  const _ThumbFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: QueryPicColors.chipTintLight,
      child: const Center(
        child: Icon(Icons.image_outlined, color: Colors.grey),
      ),
    );
  }
}