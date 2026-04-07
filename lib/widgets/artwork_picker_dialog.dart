import 'package:file_picker/file_picker.dart' as fp;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../focus/focusable_button.dart';
import '../focus/focusable_wrapper.dart';
import '../i18n/strings.g.dart';
import '../services/plex_client.dart';
import '../utils/dialogs.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/app_icon.dart';
import '../widgets/plex_optimized_image.dart';

class ArtworkPickerDialog extends StatefulWidget {
  final PlexClient client;
  final String ratingKey;
  final String element; // "posters" or "arts"

  const ArtworkPickerDialog({
    super.key,
    required this.client,
    required this.ratingKey,
    required this.element,
  });

  @override
  State<ArtworkPickerDialog> createState() => _ArtworkPickerDialogState();
}

class _ArtworkPickerDialogState extends State<ArtworkPickerDialog> {
  List<Map<String, dynamic>>? _artworkList;
  bool _isLoading = true;
  bool _isApplying = false;

  bool get _isPosters => widget.element == 'posters';

  @override
  void initState() {
    super.initState();
    _loadArtwork();
  }

  Future<void> _loadArtwork() async {
    final artwork = await widget.client.getAvailableArtwork(widget.ratingKey, widget.element);
    if (!mounted) return;
    setState(() {
      _artworkList = artwork;
      _isLoading = false;
    });
  }

  Future<void> _selectArtwork(Map<String, dynamic> artwork) async {
    // Use ratingKey (the artwork provider identifier) rather than key (a
    // file-serving path that is already percent-encoded).  Passing key through
    // Dio's query-parameter encoding double-encodes it, causing Plex to
    // silently ignore the selection despite returning 200.
    final url = artwork['ratingKey'] as String? ?? artwork['key'] as String?;
    if (url == null || _isApplying) return;

    setState(() => _isApplying = true);

    final success = await widget.client.setArtworkFromUrl(widget.ratingKey, widget.element, url);

    if (!mounted) return;
    setState(() => _isApplying = false);

    if (success) {
      showSuccessSnackBar(context, t.metadataEdit.artworkUpdated);
      Navigator.pop(context, true);
    } else {
      showErrorSnackBar(context, t.metadataEdit.artworkUpdateFailed);
    }
  }

  Future<void> _addFromUrl() async {
    final url = await showTextInputDialog(
      context,
      title: t.metadataEdit.fromUrl,
      labelText: t.metadataEdit.imageUrl,
      hintText: t.metadataEdit.enterImageUrl,
    );

    if (url == null || url.isEmpty || !mounted) return;

    setState(() => _isApplying = true);

    final success = await widget.client.setArtworkFromUrl(widget.ratingKey, widget.element, url);

    if (!mounted) return;
    setState(() => _isApplying = false);

    if (success) {
      showSuccessSnackBar(context, t.metadataEdit.artworkUpdated);
      Navigator.pop(context, true);
    } else {
      showErrorSnackBar(context, t.metadataEdit.artworkUpdateFailed);
    }
  }

  Future<void> _uploadFile() async {
    final result = await fp.FilePicker.platform.pickFiles(
      type: fp.FileType.image,
      withData: true,
    );

    if (result == null || result.files.isEmpty || !mounted) return;

    final bytes = result.files.first.bytes;
    if (bytes == null) return;

    setState(() => _isApplying = true);

    final success = await widget.client.uploadArtwork(widget.ratingKey, widget.element, bytes);

    if (!mounted) return;
    setState(() => _isApplying = false);

    if (success) {
      showSuccessSnackBar(context, t.metadataEdit.artworkUpdated);
      Navigator.pop(context, true);
    } else {
      showErrorSnackBar(context, t.metadataEdit.artworkUpdateFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 800,
        height: 600,
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  AppIcon(
                    _isPosters ? Symbols.image : Symbols.panorama,
                    size: 28,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 16),
                  Text(
                    _isPosters ? t.metadataEdit.poster : t.metadataEdit.background,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  FocusableButton(
                    onPressed: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const AppIcon(Symbols.close, size: 20),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 1,
              color: Colors.white.withOpacity(0.1),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressAnimation())
                  : _artworkList == null || _artworkList!.isEmpty
                      ? Center(
                          child: Text(
                            t.metadataEdit.noArtworkAvailable,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 16,
                            ),
                          ),
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.all(24),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _isPosters ? 4 : 2,
                            childAspectRatio: _isPosters ? 2 / 3 : 16 / 9,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: _artworkList!.length,
                          itemBuilder: (context, index) {
                            final artwork = _artworkList![index];
                            final url = artwork['thumb'] as String? ?? artwork['key'] as String?;
                            final isSelected = artwork['selected'] == true;

                            if (url == null) return const SizedBox();

                            return FocusableWrapper(
                              onSelect: () => _selectArtwork(artwork),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected
                                            ? Theme.of(context).colorScheme.primary
                                            : Colors.white.withOpacity(0.1),
                                        width: isSelected ? 3 : 1,
                                      ),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: PlexOptimizedImage(
                                      imagePath: widget.client.getThumbnailUrl(url),
                                      width: double.infinity,
                                      height: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  if (isSelected)
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context).colorScheme.primary,
                                          shape: BoxShape.circle,
                                        ),
                                        child: const AppIcon(
                                          Symbols.check,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
            Container(
              height: 1,
              color: Colors.white.withOpacity(0.1),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FocusableButton(
                    onPressed: _isApplying ? null : _addFromUrl,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppIcon(Symbols.link, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            t.metadataEdit.fromUrl,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  FocusableButton(
                    onPressed: _isApplying ? null : _uploadFile,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _isApplying
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const AppIcon(Symbols.upload, size: 20, color: Colors.white),
                                const SizedBox(width: 8),
                                Text(
                                  t.metadataEdit.uploadFile,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CircularProgressAnimation extends StatelessWidget {
  const CircularProgressAnimation({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 48,
      height: 48,
      child: CircularProgressIndicator(),
    );
  }
}