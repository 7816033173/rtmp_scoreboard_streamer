#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint rtmp_scoreboard_streamer.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'rtmp_scoreboard_streamer'
  s.version          = '0.0.1'
  s.summary          = 'Camera to scoreboard overlay to RTMP for Sportzdom live streams.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # Pinned: 2.0.9 is the last release on CocoaPods (2.1+ is Swift Package Manager only), and it
  # already includes RTMP. FlutterFlow builds iOS with CocoaPods.
  s.dependency 'HaishinKit', '2.0.9'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.10'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'rtmp_scoreboard_streamer_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
