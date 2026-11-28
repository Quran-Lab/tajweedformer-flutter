// Which host this platform uses: the web's on the web, else the native one (host_select_io.dart). Internal.
export 'host_select_io.dart' if (dart.library.js_interop) 'web/host_select_web.dart';
