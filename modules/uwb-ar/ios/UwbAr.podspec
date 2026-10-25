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
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'
  s.dependency 'WebRTC-lib', '154.0.0'
  s.frameworks = 'ARKit', 'RealityKit', 'NearbyInteraction', 'MultipeerConnectivity', 'ReplayKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'SWIFT_VERSION' => '5.0',
    'SWIFT_STRICT_CONCURRENCY' => 'minimal'
  }
  s.source_files = "**/*.{h,m,swift}"
end
