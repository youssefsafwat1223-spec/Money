Pod::Spec.new do |s|
  s.name             = 'native_glass_navbar'
  s.version          = '1.0.2'
  s.summary          = 'Native iOS Liquid Glass tab bar for Flutter.'
  s.description      = <<-DESC
Native iOS Liquid Glass tab bar for Flutter, vendored locally for Money.
                       DESC
  s.homepage         = 'https://github.com/TechSupportz/native_glass_navbar'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'TechSupportz' => 'opensource@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
