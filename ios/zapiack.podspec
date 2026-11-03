#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint zapiack.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'zapiack'
  s.version          = '0.1.0'
  s.summary          = 'Push notifications for Flutter with Zapiack.'
  s.description      = <<-DESC
Register devices, show rich push, and follow what people do after a tap.
                       DESC
  s.homepage         = 'https://zapiack.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Zapiack' => 'support@zapiack.com' }
  s.source           = { :path => '.' }
  s.source_files = 'zapiack/Sources/zapiack/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'zapiack_privacy' => ['zapiack/Sources/zapiack/PrivacyInfo.xcprivacy']}
end
