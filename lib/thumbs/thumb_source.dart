/// Where a video link's title and thumbnail come from. Requests are built
/// only from the video ID the app already extracted and go to each site's
/// official oEmbed address; the saved page is never fetched.
library;

class VideoSource {
  const VideoSource({
    required this.site,
    required this.oembed,
    required this.imageHosts,
    this.directThumb,
  });

  /// The website group, matched against the user's per-site switches.
  final String site;

  /// The site's oEmbed address for this video: a small JSON reply with the
  /// title and a thumbnail address.
  final Uri oembed;

  /// Hosts a thumbnail may come from (a `.suffix` entry allows subdomains).
  final Set<String> imageHosts;

  /// A thumbnail address known without asking (YouTube), used in place of
  /// the one in the oEmbed reply.
  final Uri? directThumb;
}

/// Sites that can have titles and thumbnails, by website group.
const thumbSites = {
  'youtube.com': 'YouTube',
  'vimeo.com': 'Vimeo',
  'dailymotion.com': 'Dailymotion',
};

/// The only hosts asked for oEmbed replies.
const oembedHosts = {'www.youtube.com', 'vimeo.com', 'www.dailymotion.com'};

/// The only hosts thumbnails are downloaded from.
const thumbHosts = {'i.ytimg.com', 'i.vimeocdn.com', '.dmcdn.net'};

final _youtube = RegExp(r'^youtube:([A-Za-z0-9_-]{11})$');
final _vimeo = RegExp(r'^vimeo:(\d{5,12})$');
final _dailymotion = RegExp(r'^dailymotion:(x[a-z0-9]{3,12})$', caseSensitive: false);

/// The source for a link's canonical key, or null if the site isn't supported.
VideoSource? videoSourceFor(String canonicalKey) {
  if (_youtube.firstMatch(canonicalKey) case final m?) {
    final id = m[1]!;
    return VideoSource(
      site: 'youtube.com',
      oembed: Uri.https('www.youtube.com', '/oembed',
          {'url': 'https://www.youtube.com/watch?v=$id', 'format': 'json'}),
      // hqdefault: 480x360 (16:9 picture with black bars, cropped when shown),
      // exists for every video.
      directThumb: Uri.https('i.ytimg.com', '/vi/$id/hqdefault.jpg'),
      imageHosts: const {'i.ytimg.com'},
    );
  }
  if (_vimeo.firstMatch(canonicalKey) case final m?) {
    return VideoSource(
      site: 'vimeo.com',
      oembed: Uri.https('vimeo.com', '/api/oembed.json', {'url': 'https://vimeo.com/${m[1]}'}),
      imageHosts: const {'i.vimeocdn.com'},
    );
  }
  if (_dailymotion.firstMatch(canonicalKey) case final m?) {
    return VideoSource(
      site: 'dailymotion.com',
      oembed: Uri.https('www.dailymotion.com', '/services/oembed',
          {'url': 'https://www.dailymotion.com/video/${m[1]}', 'format': 'json'}),
      imageHosts: const {'.dmcdn.net'},
    );
  }
  return null;
}
