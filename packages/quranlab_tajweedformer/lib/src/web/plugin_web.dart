// The web's plugin class: Flutter registers it in a web build. The host itself (web_host.dart) is chosen by the
// conditional import of host_select.dart and loads Quran Lab's hosted loader at the first call. Internal.
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class TajweedFormerWeb {
  static void registerWith(Registrar registrar) {}
}
