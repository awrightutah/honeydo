import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  runApp(const FetcherSpikeApp());
}

class FetcherSpikeApp extends StatelessWidget {
  const FetcherSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Webview Fetcher Spike',
      theme: ThemeData(useMaterial3: true),
      home: const FetcherScreen(),
    );
  }
}

// Preset URLs from the fetcher spike test set + one edge case (roundup page).
class _Preset {
  const _Preset(this.label, this.url);
  final String label;
  final String url;
}

const List<_Preset> _presets = [
  _Preset(
    'Allrecipes',
    'https://www.allrecipes.com/recipe/10813/best-chocolate-chip-cookies/',
  ),
  _Preset(
    'Food Network',
    'https://www.foodnetwork.com/recipes/ina-garten/beattys-chocolate-cake-recipe-1947521',
  ),
  _Preset(
    'Damn Delicious',
    'https://damndelicious.net/2025/09/12/chicken-divan/',
  ),
  _Preset(
    'BA Roundup (edge)',
    'https://www.bonappetit.com/gallery/best-pasta-recipes',
  ),
];

class FetcherScreen extends StatefulWidget {
  const FetcherScreen({super.key});

  @override
  State<FetcherScreen> createState() => _FetcherScreenState();
}

class _FetcherScreenState extends State<FetcherScreen> {
  late final WebViewController _controller;
  String _currentLabel = _presets[0].label;
  String _status = 'initializing...';
  bool _pageLoadFinished = false;
  int? _htmlByteCount;
  bool? _hasJsonLd;
  String? _schemaType;
  String? _htmlPreview;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _status = 'page loading...';
              _pageLoadFinished = false;
            });
          },
          onPageFinished: (url) {
            setState(() {
              _status = 'page finished';
              _pageLoadFinished = true;
            });
          },
          onWebResourceError: (error) {
            setState(() {
              _errorMessage = '${error.errorType}: ${error.description}';
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(_presets[0].url));
  }

  void _loadPreset(_Preset preset) {
    setState(() {
      _currentLabel = preset.label;
      _status = 'loading: ${preset.label}';
      _pageLoadFinished = false;
      _htmlByteCount = null;
      _hasJsonLd = null;
      _schemaType = null;
      _htmlPreview = null;
      _errorMessage = null;
    });
    _controller.loadRequest(Uri.parse(preset.url));
  }

  Future<void> _extractHtml() async {
    setState(() {
      _status = 'extracting HTML...';
      _htmlByteCount = null;
      _hasJsonLd = null;
      _schemaType = null;
      _htmlPreview = null;
      _errorMessage = null;
    });

    try {
      // Give JS a moment to populate dynamic content after page-finished.
      await Future.delayed(const Duration(seconds: 2));

      final result = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      final html = result.toString();
      String cleaned = html;
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        cleaned = cleaned.substring(1, cleaned.length - 1);
      }

      // First @type token in any JSON-LD block — diagnostic for
      // single-recipe (Recipe) vs roundup (CollectionPage/ItemList/etc).
      final typeMatch =
          RegExp(r'"@type"\s*:\s*"([A-Za-z]+)"').firstMatch(cleaned);
      final schemaType = typeMatch?.group(1);

      setState(() {
        _htmlByteCount = cleaned.length;
        _hasJsonLd = cleaned.contains('application/ld+json');
        _schemaType = schemaType;
        _htmlPreview = cleaned.length > 500
            ? '${cleaned.substring(0, 500)}...'
            : cleaned;
        _status = 'extraction complete';
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Extraction error: $e';
        _status = 'extraction failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Spike: $_currentLabel'),
        toolbarHeight: 40,
      ),
      body: Column(
        children: [
          // Preset URL buttons — tap to navigate the webview to that URL.
          // No flutter restart needed; the webview just navigates.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: Colors.grey[100],
            width: double.infinity,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final preset in _presets)
                  ElevatedButton(
                    onPressed: () => _loadPreset(preset),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      preset.label,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
              ],
            ),
          ),
          // Status + extract + result row
          Container(
            padding: const EdgeInsets.all(8.0),
            color: Colors.grey[200],
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status: $_status', style: const TextStyle(fontSize: 12)),
                if (_errorMessage != null)
                  Text(
                    'ERROR: $_errorMessage',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                if (_htmlByteCount != null) ...[
                  Text(
                    'HTML bytes: $_htmlByteCount  |  has JSON-LD: $_hasJsonLd',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  if (_schemaType != null)
                    Text(
                      'First @type in JSON-LD: $_schemaType',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold),
                    )
                  else if (_hasJsonLd == false)
                    const Text(
                      'No JSON-LD scripts present',
                      style: TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                ],
                const SizedBox(height: 4),
                ElevatedButton(
                  onPressed: _pageLoadFinished ? _extractHtml : null,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Extract HTML'),
                ),
                if (_htmlPreview != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'preview: ${_htmlPreview!.length > 80 ? _htmlPreview!.substring(0, 80) : _htmlPreview!}...',
                    style: const TextStyle(fontSize: 10),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
