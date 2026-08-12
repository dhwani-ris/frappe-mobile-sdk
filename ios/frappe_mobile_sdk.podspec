Pod::Spec.new do |s|
  s.name             = 'frappe_mobile_sdk'
  s.version          = '2.0.0'
  s.summary          = 'Flutter SDK for offline-first Frappe/ERPNext mobile apps.'
  s.description      = <<-DESC
    Flutter SDK providing auth, API access, dynamic forms, and sync-aware offline
    data operations for Frappe/ERPNext backends.
  DESC
  s.homepage         = 'https://github.com/dhwani-ris/frappe-mobile-sdk'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dhwani RIS' => 'info@dhwaniris.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'frappe_mobile_sdk/Sources/frappe_mobile_sdk/**/*.swift'
  s.dependency 'Flutter'
  # Keep in lockstep with frappe_mobile_sdk/Package.swift's `.iOS("13.0")`.
  # Diverging floors mean the same plugin resolves differently depending on
  # whether the host integrates via CocoaPods or SPM. 13.0 is also Flutter's
  # own minimum, so nothing is lost by raising it here.
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version    = '5.0'
end
