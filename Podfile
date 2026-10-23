platform :ios, '16.0'

source 'https://cdn.cocoapods.org/'

target 'VideoSniffer' do
  use_frameworks! :linkage => :static

  pod 'IJKMediaFramework', :podspec => 'IJKMediaFramework.podspec'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
