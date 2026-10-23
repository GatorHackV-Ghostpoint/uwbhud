Pod::Spec.new do |s|
  s.name           = 'UwbAr'
  s.version        = '0.1.0'
  s.summary        = 'iPhone-to-iPhone UWB ranging rendered in an ARKit camera view'
  s.description    = s.summary
  s.author         = ''
  s.homepage       = 'https://example.com'
  s.license        = 'MIT'
  s.platforms      = { :ios => '16.4' }
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'ARKit', 'RealityKit', 'NearbyInteraction', 'MultipeerConnectivity'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
  s.source_files = "**/*.{h,m,swift}"
end
