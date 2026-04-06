import '../../data/models/app_media.dart';

/// Remote poster URL for [AppMedia] when the API supplied [AppMedia.posterPath].
/// Returns null when there is no remote artwork (caller may use a local file fallback).
String? remotePosterUrlForAppMedia(AppMedia media) {
  final value = (media.posterPath ?? '').trim();
  if (value.isEmpty) return null;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    return value;
  }
  if (value.startsWith('/')) return 'https://image.tmdb.org/t/p/w500$value';
  return value;
}
