#
# quranlab_tajweedformer has no CocoaPods integration: the Apple SDK it wraps (TajweedFormer) ships only as a Swift
# package, and the CocoaPods registry becomes read-only on 2026-12-02. This file exists so that an app still on
# CocoaPods gets a clear message instead of a missing module at build time.
#
Pod::Spec.new do |s|
  s.name             = 'quranlab_tajweedformer'
  s.version          = '4.1.0'
  s.summary          = 'TajweedFormer V4 for Flutter (iOS needs Swift Package Manager).'
  s.homepage         = 'https://sdk.quranlab.ai'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Quran Lab' => 'https://quranlab.ai' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '15.0'
  raise <<~MSG
    quranlab_tajweedformer needs Flutter's Swift Package Manager integration on iOS: the TajweedFormer SDK
    is a Swift package only. Turn it on with `flutter config --enable-swift-package-manager` (on by default
    since Flutter 3.44), then run `flutter clean` and build again. Flutter 3.44 or later is needed.
  MSG
end
